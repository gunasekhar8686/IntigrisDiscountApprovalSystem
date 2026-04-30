# Intigris Discount Approval System

A Salesforce metadata project that implements a configurable, multi-tier discount approval workflow on the Opportunity object. Sales reps submit discount requests through a Lightning Web Component; the platform routes each request to the correct approver queue based on Custom Metadata tiers, enforces approval rights via a Custom Permission, and writes an immutable audit trail on every state change.

---

## Table of Contents

1. [Architecture Decisions & Trade-offs](#1-architecture-decisions--trade-offs)
2. [AI Workflow](#2-ai-workflow)
3. [Edge Cases](#3-edge-cases)
4. [Setup Instructions](#4-setup-instructions)
5. [What I Would Change With More Time](#5-what-i-would-change-with-more-time)

---

## 1. Architecture Decisions & Trade-offs

### Why Custom Metadata over Custom Object for tiers

The discount tier thresholds (0–9.99 % auto-approve, 10–24.99 % Sales Manager, etc.) are stored in `Discount_Approval_Tier__mdt` rather than a regular Custom Object.

| Dimension | Custom Metadata | Custom Object |
|-----------|----------------|---------------|
| Deployment | Included in `package.xml`; moves between orgs with source deploy | Requires data migration scripts or manual re-entry per org |
| Apex access | Queried at compile time or cached in static variables; counts against SOQL limits like any query | Same SOQL cost, but no deployment portability |
| Sandbox refresh | Records survive a sandbox refresh | Records are wiped on full sandbox refresh |
| Protection | Can be marked `protected` in a managed package | No equivalent concept |

**Trade-off accepted:** Custom Metadata records cannot be modified through a standard UI DML path (they require `Metadata.operations.enqueueUpdate` or a deployment). For an admin who wants to adjust tier thresholds in production without a deployment, this is friction. In a production system we would document a lightweight change process or expose a custom admin screen backed by the Metadata API.

---

### Why snapshot the approver level at create time

`Required_Approver_Level__c` and `Final_Discount__c` are written to the `Discount_Request__c` record at the moment of insertion and never recalculated.

**Reason:** If an administrator changes the Custom Metadata tier boundaries after a request is already pending, the original routing decision must be preserved. An approver who accepts or rejects a request must see exactly what was asked at submission time — not a retrospectively recalculated value. The snapshot also survives changes to the CMDT without corrupting historical audit records.

**Trade-off accepted:** A request submitted at 24.9 % before a tier boundary moves to 20 % will still route to Sales Manager, even though the new boundary would send it to Director. This is intentional and desirable for audit consistency.

---

### Why Queue-based approval routing

Each tier maps to a Salesforce Queue (`Sales_Manager_Approvals`, `Director_Approvals`, `CFO_Approvals`). The trigger sets `OwnerId` to the resolved Queue Id.

**Benefits:**
- Any member of the queue can action the request, not just a single named user — no single point of failure if a manager is on leave.
- Queue membership is managed in Setup with no code changes required.
- The notification flow sends email to the queue's shared inbox, giving the team a single actionable address.
- Queue DeveloperNames are stored in Custom Metadata, so routing rules and queue configuration are decoupled: changing a queue's membership never requires a code deployment.

**Trade-off accepted:** Salesforce queue ownership does not enforce record-level sharing by default. If the org's Opportunity OWD is Private, approvers may not be able to see the parent Opportunity without an explicit sharing rule or Apex Managed Sharing. This is deferred (see Section 3).

---

### Why Custom Permission for approval rights

`FeatureManagement.checkPermission('Approve_Discount_Request')` is called in `DiscountRequestService.processApprovals` before any status change to `Approved` or `Rejected` is committed.

**Reason:** Profiles and permission sets control what fields a user can edit but do not express business-level capabilities like "this user is allowed to approve discounts." A Custom Permission is precisely that concept: a named capability that can be granted via Permission Set, checked programmatically, and revoked without a code change.

**Alternative considered:** A custom field on User (`Can_Approve_Discounts__c`). Rejected because:
- It bypasses the standard permission framework.
- It cannot be included in a Permission Set or Permission Set Group.
- Checking it requires an extra SOQL query on User inside the trigger.

---

### Why a separate Audit object over field history tracking

`Discount_Request_Audit__c` is an append-only object written by the trigger. Salesforce Field History Tracking was considered and rejected for the following reasons:

| Dimension | Field History Tracking | Audit Object |
|-----------|----------------------|--------------|
| Retention | 18 months (standard); longer with add-on | Permanent unless explicitly deleted |
| Custom data | Field + old/new value only | Free-form `Comments__c`, `Action__c`, `Performed_By__c` |
| Queryable in SOQL | Via `FieldHistory` child relationship | Direct SOQL on the object |
| Reportable | Limited; not available in all report types | Full Report Builder support |
| Package-deployable | Configuration only; no metadata file | Full metadata + data portability |

**Trade-off accepted:** The audit object consumes data storage. In a high-volume org (thousands of requests per day) this cost is real. For the current scope it is negligible.

---

## 2. AI Workflow

### Tools used

- **Claude (claude.ai)** — architecture decisions, Apex class design, metadata XML generation, and code review.
- **VS Code with Salesforce Extension Pack** — local file editing, Org authentication, and deployment via the integrated terminal.

### Specific example — Queue routing design

The queue-based routing pattern was designed in collaboration with Claude. The initial question was: *"How should the system route a discount request to the right approver without hardcoding user Ids?"*

Claude proposed two options:
1. Store approver user Ids or role names in Custom Metadata and assign `OwnerId` directly to a User.
2. Create named Queues per tier and store only the Queue `DeveloperName` in Custom Metadata, resolving the Queue Id at runtime via a SOQL query on `Group`.

Option 2 was chosen because it decouples the approval group membership from the code entirely. Claude then generated `DiscountTierSelector.resolveQueueIds()` with a static cache to avoid repeated `Group` queries across a bulk batch.

### Where I overrode AI — Custom Metadata vs Custom Object

Claude's first suggestion for tier configuration was a Custom Object with standard CRUD access so admins could edit thresholds directly in a list view. After discussing deployment requirements (the system must move intact from sandbox to production without a data migration step), the decision shifted to Custom Metadata. The trade-off (admin friction on threshold changes) was accepted consciously and documented above.

### Where AI broke down

- **Deployment verification:** Claude cannot connect to a Salesforce org, run `sf project deploy`, or confirm that generated metadata XML is syntactically valid against the live Metadata API. Every XML file required manual review and a test deploy to catch issues such as missing required elements or incorrect operator names in flow filters.
- **Org-specific configuration:** Queue email addresses, profile names for test users (`Standard User`), and Custom Metadata record DeveloperNames must match what exists in the target org. Claude generated plausible values; the developer must verify them against the actual org before running tests.
- **FeatureManagement in runAs context:** Claude flagged that `FeatureManagement.checkPermission` behaviour inside `System.runAs()` in tests is a known grey area and recommended manual testing of the `testUnauthorisedApproval` scenario after deployment.

---

## 3. Edge Cases

### Handled

| Scenario | Implementation |
|----------|---------------|
| **Closed Won / Closed Lost opportunity** | `processNewRequests` queries the parent Opportunity's `StageName` and calls `addError` if closed. The insert fails cleanly with a user-readable message. |
| **Concurrent duplicate Pending requests** | A `FOR UPDATE` SOQL query locks existing Pending records on the same Opportunity before the duplicate check. Two simultaneous inserts cannot both pass the guard. |
| **Stacked discounts** | Each approval writes `Final_Discount__c` back to `Opportunity.Discount__c`. The latest approved request always wins; no accumulation occurs. |
| **Unauthorised approval attempt** | `FeatureManagement.checkPermission('Approve_Discount_Request')` is checked in the `after update` trigger. Users without the permission receive an `AuraHandledException` regardless of which tool they use to update the record (LWC, API, Workbench, Data Loader). |

### Deferred

| Scenario | Reason deferred |
|----------|----------------|
| **Multi-currency** | Discount values are percentages, not currency amounts. `Opportunity.Discount__c` is a Number field. Multi-currency has no bearing on the workflow. |
| **Opportunity sharing with approvers** | If Opportunity OWD is Private, queue members may not see the parent record. The fix is Apex Managed Sharing triggered on Discount Request insert. Deferred because the target org uses Public Read/Write OWD for Opportunities. |
| **Email deliverability in scratch orgs** | Salesforce disables outbound email in scratch orgs by default. The notification flow will execute without error but no email will be received. Enable deliverability in Setup → Email → Deliverability for manual testing. |

---

## 4. Setup Instructions

### Prerequisites

- Salesforce CLI (`sf`) installed and up to date.
- VS Code with the Salesforce Extension Pack.
- A target org already provisioned (Developer Edition or Sandbox).

### Steps

**1. Clone the repository**

```bash
git clone https://github.com/<your-username>/IntigrisDiscountApprovalSystem.git
cd IntigrisDiscountApprovalSystem
```

**2. Authenticate to your org**

```bash
sf org login web --alias AgentforceOrg
```

**3. Deploy all metadata**

```bash
sf project deploy start --target-org AgentforceOrg --manifest manifest/package.xml
```

**4. Verify deployment**

```bash
sf project deploy report --target-org AgentforceOrg
```

**5. Run Apex tests**

```bash
sf apex run test --target-org AgentforceOrg --class-names DiscountRequestTest --result-format human --wait 10
```

**6. Assign Permission Sets to users**

```bash
# Assign Discount Requester to sales reps
sf org assign permset --name Discount_Requester --on-behalf-of <username> --target-org AgentforceOrg

# Assign Discount Approver to managers / directors / CFO
sf org assign permset --name Discount_Approver --on-behalf-of <username> --target-org AgentforceOrg
```

**7. Add users to Queues**

Navigate to **Setup → Queues** and add the appropriate users or public groups to:
- `Sales Manager Approvals`
- `Director Approvals`
- `CFO Approvals`

**8. Verify Custom Metadata tier records**

Navigate to **Setup → Custom Metadata Types → Discount Approval Tier → Manage Records** and confirm the four records (Auto Approve, Sales Manager, Director, CFO) are present with the correct Min/Max values.

**9. Add the LWC to the Opportunity page**

Navigate to any Opportunity record → click the gear icon → **Edit Page** → drag the **Discount Request Panel** component onto the layout → **Save and Activate**.

---

## 5. What I Would Change With More Time

### Stretch Goal 1 — Auto-escalation

If a Pending request has not been actioned within N business days, automatically escalate it to the next tier queue. Implementation: a Scheduled Flow or Scheduled Apex job that queries Pending requests older than the threshold and updates `OwnerId` to the next queue, creating an audit record for the escalation.

### Stretch Goal 2 — Org-wide approvals queue LWC

A second LWC component targeted at `lightning__AppPage` that shows all Pending discount requests across all Opportunities in a single view. Approvers currently have to navigate to individual Opportunity records. A centralised queue view with bulk approve/reject capability would significantly improve approver productivity.

### Stretch Goal 3 — Apex REST endpoint

Expose `GET /services/apexrest/discountRequests/{opportunityId}` and `POST /services/apexrest/discountRequests` so external systems (ERP, CPQ tools) can query and submit discount requests without a Salesforce UI. Would include OAuth 2.0 JWT bearer flow for server-to-server authentication.

### Additional improvements

| Area | Change |
|------|--------|
| **LWC testing** | Add Jest unit tests for `discountRequestPanel` covering empty state, badge colour rendering, and button visibility logic. |
| **Apex Managed Sharing** | Add a sharing reason on `Discount_Request__c` and write sharing records when a request is assigned to a queue, granting queue members read access to the parent Opportunity. |
| **Platform Events** | Publish a `Discount_Decision__e` Platform Event on approval/rejection so external subscribers (ERP, Slack integration) receive real-time notifications without polling. |
| **Duplicate check UX** | Surface the existing Pending request's link in the LWC empty-state message so the rep can navigate directly to it rather than receiving only a toast error. |
| **Governor limit headroom reporting** | Add `Limits.getQueries()` and `Limits.getDMLStatements()` assertions to `testBulk` so any future regression that adds a SOQL inside a loop is caught immediately. |

---

## Project Structure

```
IntigrisDiscountApprovalSystem/
├── manifest/
│   └── package.xml
├── config/
│   └── project-scratch-def.json
├── force-app/main/default/
│   ├── classes/
│   │   ├── DiscountTierSelector.cls
│   │   ├── DiscountRequestService.cls
│   │   ├── DiscountRequestHandler.cls
│   │   ├── DiscountRequestController.cls
│   │   └── DiscountRequestTest.cls
│   ├── triggers/
│   │   └── DiscountRequestTrigger.trigger
│   ├── lwc/
│   │   └── discountRequestPanel/
│   ├── objects/
│   │   ├── Discount_Request__c/
│   │   ├── Discount_Request_Audit__c/
│   │   ├── Discount_Approval_Tier__mdt/
│   │   └── Opportunity/fields/
│   ├── customMetadata/
│   ├── customPermissions/
│   ├── permissionsets/
│   ├── queues/
│   └── flows/
└── sfdx-project.json
```

---

*Built by Guna Sekhar P. — Intigris Salesforce Discount Approval System*
