/**
 * @description Core business logic for Discount_Request__c. Called exclusively
 *              by DiscountRequestHandler. Covers all four trigger contexts:
 *              before-insert (validation + field setting), after-insert (side
 *              effects), before-update (rejection validation), and after-update
 *              (approval stamping + audit).
 *
 *              All methods are bulk-safe — no SOQL or DML inside loops.
 *
 * @author      Guna Sekhar P.
 */
public without sharing class DiscountRequestService {

    // ─────────────────────────────────────────────────────────────────────────
    // BEFORE INSERT — Validation + Field Setting
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Validates each incoming Discount Request and sets
     *              Required_Approver_Level__c, Status__c, OwnerId, and
     *              Final_Discount__c before the record is saved.
     *
     *              Validation order per record:
     *                1. Opportunity must exist and be open (IsClosed = false).
     *                2. No existing Pending request on the same Opportunity.
     *                3. A matching Custom Metadata tier must be configured.
     *
     *              FOR UPDATE is used on the pending-request query to prevent
     *              two simultaneous inserts from both passing the duplicate check.
     *              WITH USER_MODE is intentionally omitted — it is incompatible
     *              with FOR UPDATE in Salesforce.
     *
     * @param requests Trigger.new list from the before-insert context.
     */
    public static void handleBeforeInsert(List<Discount_Request__c> requests) {

        // Collect all referenced Opportunity Ids for bulk query
        Set<Id> oppIds = new Set<Id>();
        for (Discount_Request__c req : requests) {
            if (req.Opportunity__c != null) {
                oppIds.add(req.Opportunity__c);
            }
        }

        // Single query for all parent Opportunities
        Map<Id, Opportunity> oppsMap = new Map<Id, Opportunity>([
            SELECT Id, IsClosed
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        // FOR UPDATE locks existing Pending rows — prevents concurrent duplicate inserts.
        // WITH USER_MODE is incompatible with FOR UPDATE and is intentionally omitted.
        Map<Id, Discount_Request__c> pendingByOpp = new Map<Id, Discount_Request__c>();
        for (Discount_Request__c existing : [
            SELECT Id, Opportunity__c
            FROM Discount_Request__c
            WHERE Opportunity__c IN :oppIds
            AND Status__c = 'Pending'
            AND Is_Active__c = true
            FOR UPDATE
        ]) {
            pendingByOpp.put(existing.Opportunity__c, existing);
        }

        // Pre-resolve queue Ids in bulk — DiscountTierSelector caches results internally
        Set<String> queueDevNames = new Set<String>();
        for (Discount_Request__c req : requests) {
            Discount_Approval_Tier__mdt tier =
                DiscountTierSelector.getMatchingTier(req.Requested_Discount__c);
            if (tier != null && !tier.Auto_Approve__c && String.isNotBlank(tier.Queue_DeveloperName__c)) {
                queueDevNames.add(tier.Queue_DeveloperName__c);
            }
        }
        Map<String, Id> queueIds = DiscountTierSelector.resolveQueueIds(queueDevNames);

        // Process each request — addError rolls back only the individual record in a bulk insert
        for (Discount_Request__c req : requests) {

            Opportunity opp = oppsMap.get(req.Opportunity__c);

            if (opp == null) {
                req.addError('Invalid Opportunity.');
                continue;
            }

            // IsClosed covers ALL closed stages (Closed Won, Closed Lost, custom closed stages)
            // — more robust than checking specific StageName values
            if (opp.IsClosed) {
                req.addError('Cannot create discount request on closed Opportunities.');
                continue;
            }

            if (pendingByOpp.containsKey(req.Opportunity__c)) {
                req.addError('A Pending request already exists.');
                continue;
            }

            // Each call is O(1) — tier list is cached in a static variable
            Discount_Approval_Tier__mdt tier =
                DiscountTierSelector.getMatchingTier(req.Requested_Discount__c);

            if (tier == null) {
                req.addError('No approval tier configured.');
                continue;
            }

            // Snapshot approver level and discount at submission time — never recomputed.
            // If tier boundaries change later, historical requests are unaffected.
            req.Required_Approver_Level__c = tier.Approver_Level__c;
            req.Final_Discount__c          = req.Requested_Discount__c;
            req.Is_Active__c               = true;

            if (tier.Auto_Approve__c) {
                // Below-threshold requests bypass the queue entirely
                req.Status__c                  = 'Auto-Approved';
                req.Required_Approver_Level__c = 'Auto Approve';
                req.Decision_Timestamp__c      = System.now();
            } else {
                req.Status__c = 'Pending';

                // Assign ownership to the approver queue — queue members receive email via
                // sendQueueNotifications in after-insert
                Id queueId = queueIds.get(tier.Queue_DeveloperName__c);
                if (queueId != null) {
                    req.OwnerId = queueId;
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER INSERT — Side Effects
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Performs post-insert side effects for all newly created
     *              Discount Requests:
     *                - Writes a Submitted (or Auto-Approved) audit record.
     *                - Updates Opportunity.Discount__c for auto-approved requests.
     *                - Deactivates any prior Approved/Auto-Approved requests on
     *                  the same Opportunity (stacked-discount behaviour).
     *                - Sends HTML email notifications to queue members for all
     *                  Pending requests.
     *
     * @param requests Trigger.new list from the after-insert context.
     */
    public static void handleAfterInsert(List<Discount_Request__c> requests) {

        Set<Id> oppIds            = new Set<Id>();
        Set<Id> newReqIds         = new Set<Id>();
        Map<Id, Opportunity> oppsToUpdate     = new Map<Id, Opportunity>();
        List<Discount_Request_Audit__c> audits = new List<Discount_Request_Audit__c>();
        DateTime now = System.now();

        for (Discount_Request__c req : requests) {
            if (req.Opportunity__c != null) oppIds.add(req.Opportunity__c);
            newReqIds.add(req.Id);

            // One audit entry per inserted record — action is 'Submitted' or 'Auto-Approved'
            audits.add(new Discount_Request_Audit__c(
                Discount_Request__c = req.Id,
                Action__c           = req.Status__c == 'Auto-Approved' ? 'Auto-Approved' : 'Submitted',
                Performed_By__c     = UserInfo.getUserId(),
                Comments__c         = req.Reason__c,
                Timestamp__c        = now
            ));

            // Auto-approved requests update Opportunity.Discount__c immediately
            if (req.Status__c == 'Auto-Approved') {
                oppsToUpdate.put(req.Opportunity__c,
                    new Opportunity(Id = req.Opportunity__c, Discount__c = req.Final_Discount__c)
                );
            }
        }

        // Stacked discount: deactivate prior Approved/Auto-Approved requests on the same Opp.
        // The newest approval always takes precedence — old requests are flagged Is_Active__c = false.
        List<Discount_Request__c> toDeactivate = new List<Discount_Request__c>();
        for (Discount_Request__c old : [
            SELECT Id
            FROM   Discount_Request__c
            WHERE  Opportunity__c IN :oppIds
            AND    Status__c IN ('Approved', 'Auto-Approved')
            AND    Is_Active__c = true
            AND    Id NOT IN :newReqIds
        ]) {
            toDeactivate.add(new Discount_Request__c(Id = old.Id, Is_Active__c = false));
        }

        if (!audits.isEmpty())       insert audits;
        if (!oppsToUpdate.isEmpty()) update oppsToUpdate.values();
        if (!toDeactivate.isEmpty()) update toDeactivate;

        // Send email notifications to queue members for all Pending requests only.
        // Auto-Approved requests require no approver action.
        List<Discount_Request__c> pendingInserts = new List<Discount_Request__c>();
        for (Discount_Request__c req : requests) {
            if (req.Status__c == 'Pending') pendingInserts.add(req);
        }
        if (!pendingInserts.isEmpty()) {
            sendQueueNotifications(pendingInserts);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EMAIL NOTIFICATIONS — Bulk-safe
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Sends an HTML approval-request email to each approver queue's
     *              shared inbox and to every individual queue member.
     *
     *              Bulk pattern: all recipient data is resolved in four queries
     *              outside any loop, then all emails are collected into a single
     *              List and sent with one Messaging.sendEmail call.
     *              allOrNothing = false ensures a single invalid address does not
     *              roll back the entire batch.
     *
     * @param pendingRequests List of Discount Requests with Status__c = 'Pending'.
     */
    private static void sendQueueNotifications(List<Discount_Request__c> pendingRequests) {

        // Step 1 — collect distinct queue owner Ids and Opportunity Ids
        Set<Id> queueOwnerIds = new Set<Id>();
        Set<Id> oppIds        = new Set<Id>();
        for (Discount_Request__c req : pendingRequests) {
            if (req.OwnerId != null)        queueOwnerIds.add(req.OwnerId);
            if (req.Opportunity__c != null) oppIds.add(req.Opportunity__c);
        }

        // Step 2 — queue group records for the shared queue email address
        Map<Id, Group> queuesById = new Map<Id, Group>([
            SELECT Id, Email FROM Group WHERE Id IN :queueOwnerIds AND Type = 'Queue'
        ]);

        // Step 3 — all queue members across all queues, keyed by queue Id
        Map<Id, List<Id>> memberUserIdsByQueueId = new Map<Id, List<Id>>();
        Set<Id> memberUserIds = new Set<Id>();
        for (GroupMember gm : [
            SELECT GroupId, UserOrGroupId FROM GroupMember
            WHERE  GroupId IN :queueOwnerIds AND UserOrGroupId != null
        ]) {
            if (!memberUserIdsByQueueId.containsKey(gm.GroupId)) {
                memberUserIdsByQueueId.put(gm.GroupId, new List<Id>());
            }
            memberUserIdsByQueueId.get(gm.GroupId).add(gm.UserOrGroupId);
            memberUserIds.add(gm.UserOrGroupId);
        }

        // Step 4 — email addresses for all member users (active only)
        Map<Id, String> emailByUserId = new Map<Id, String>();
        for (User u : [SELECT Id, Email FROM User WHERE Id IN :memberUserIds AND IsActive = true]) {
            emailByUserId.put(u.Id, u.Email);
        }

        // Step 5 — Opportunity names for the email body
        Map<Id, Opportunity> oppsById = new Map<Id, Opportunity>([
            SELECT Id, Name FROM Opportunity WHERE Id IN :oppIds
        ]);

        String baseUrl = System.URL.getOrgDomainUrl().toExternalForm();

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Discount_Request__c req : pendingRequests) {

            Group       queue   = queuesById.get(req.OwnerId);
            Opportunity opp     = oppsById.get(req.Opportunity__c);
            String      oppName = opp != null ? opp.Name : req.Opportunity__c;
            String      oppLink = baseUrl + '/lightning/r/Opportunity/' + req.Opportunity__c + '/view';

            String subject = 'Action Required: Discount Approval — ' + oppName + ' (' + req.Name + ')';

            // Optional reason row — only rendered when the rep provided a reason
            String reasonRow = String.isNotBlank(req.Reason__c)
                ? '<tr><td style="padding:6px 12px;color:#555;width:160px;"><b>Reason</b></td><td style="padding:6px 12px;">' + req.Reason__c + '</td></tr>'
                : '';

            // HTML email body — inline styles only (no external CSS; most email clients strip it)
            String htmlBody =
                '<!DOCTYPE html><html><body style="font-family:Arial,sans-serif;color:#333;margin:0;padding:0;">' +
                '<div style="max-width:600px;margin:30px auto;border:1px solid #e0e0e0;border-radius:6px;overflow:hidden;">' +

                '<div style="background:#0070d2;padding:20px 24px;">' +
                '<h2 style="color:#fff;margin:0;font-size:18px;">Discount Approval Request</h2>' +
                '</div>' +

                '<div style="padding:24px;">' +
                '<p style="margin-top:0;">Hello,</p>' +
                '<p>A new discount request has been submitted for <strong>' + oppName + '</strong> and is awaiting your approval. Please review the details below.</p>' +

                '<table style="width:100%;border-collapse:collapse;margin:16px 0;font-size:14px;">' +
                '<tr style="background:#f4f6f9;"><td style="padding:6px 12px;color:#555;width:160px;"><b>Request Number</b></td><td style="padding:6px 12px;">' + req.Name + '</td></tr>' +
                '<tr><td style="padding:6px 12px;color:#555;"><b>Opportunity</b></td><td style="padding:6px 12px;">' + oppName + '</td></tr>' +
                '<tr style="background:#f4f6f9;"><td style="padding:6px 12px;color:#555;"><b>Requested Discount</b></td><td style="padding:6px 12px;">' + req.Requested_Discount__c + '%</td></tr>' +
                '<tr><td style="padding:6px 12px;color:#555;"><b>Approver Level</b></td><td style="padding:6px 12px;">' + req.Required_Approver_Level__c + '</td></tr>' +
                reasonRow +
                '</table>' +

                '<p style="margin:20px 0;">' +
                '<a href="' + oppLink + '" style="background:#0070d2;color:#fff;padding:10px 20px;text-decoration:none;border-radius:4px;font-size:14px;">Review &amp; Approve Request</a>' +
                '</p>' +

                '<p style="font-size:13px;color:#666;">If the button does not work, copy and paste this link into your browser:<br>' +
                '<a href="' + oppLink + '" style="color:#0070d2;">' + oppLink + '</a></p>' +
                '</div>' +

                '<div style="background:#f4f6f9;padding:16px 24px;font-size:12px;color:#888;">' +
                'Kind regards,<br><strong>Sales Team</strong><br>This is an automated notification from Salesforce.' +
                '</div>' +
                '</div></body></html>';

            // a) Queue group shared inbox — if the queue has an email address configured
            if (queue != null && String.isNotBlank(queue.Email)) {
                Messaging.SingleEmailMessage queueMsg = new Messaging.SingleEmailMessage();
                queueMsg.setToAddresses(new List<String>{ queue.Email });
                queueMsg.setSubject(subject);
                queueMsg.setHtmlBody(htmlBody);
                queueMsg.setSaveAsActivity(false);
                emails.add(queueMsg);
            }

            // b) Individual queue members — each member receives a personal copy
            List<Id> members = memberUserIdsByQueueId.get(req.OwnerId);
            if (members != null) {
                for (Id userId : members) {
                    String memberEmail = emailByUserId.get(userId);
                    if (String.isBlank(memberEmail)) continue;
                    Messaging.SingleEmailMessage memberMsg = new Messaging.SingleEmailMessage();
                    memberMsg.setToAddresses(new List<String>{ memberEmail });
                    memberMsg.setSubject(subject);
                    memberMsg.setHtmlBody(htmlBody);
                    memberMsg.setSaveAsActivity(false);
                    emails.add(memberMsg);
                }
            }
        }

        // Single sendEmail call for all messages — allOrNothing = false skips bad addresses
        // without rolling back the entire batch
        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails, false);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BEFORE UPDATE — Validation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Validates all Approved/Rejected status transitions before
     *              the record is saved. Three checks run in order per record:
     *                1. Running user must hold the Approve_Discount_Request permission.
     *                2. Running user must be a member of the request's owner queue
     *                   (tier-level enforcement — prevents a Sales Manager from
     *                   approving a CFO-tier request).
     *                3. Rejection comments must be provided when rejecting.
     *
     *              All SOQL is executed before the loop — bulk-safe for 200+ records.
     *
     * @param newList Trigger.new from the before-update context.
     * @param oldMap  Trigger.oldMap from the before-update context.
     */
    public static void handleBeforeUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {
        Boolean hasPermission = FeatureManagement.checkPermission('Approve_Discount_Request');

        // Collect queue IDs from records transitioning to Approved/Rejected.
        // OwnerId starting with '00G' identifies a Queue (vs a User '005').
        Set<Id> queueIds = new Set<Id>();
        for (Discount_Request__c req : newList) {
            Discount_Request__c old = oldMap.get(req.Id);
            if (old.Status__c == req.Status__c) continue;
            if (req.Status__c != 'Approved' && req.Status__c != 'Rejected') continue;
            if (req.OwnerId != null && String.valueOf(req.OwnerId).startsWith('00G')) {
                queueIds.add(req.OwnerId);
            }
        }

        // Single bulk query — which of those queues does the running user belong to?
        Set<Id> memberOfQueues = new Set<Id>();
        if (!queueIds.isEmpty()) {
            for (GroupMember gm : [
                SELECT GroupId FROM GroupMember
                WHERE  GroupId       IN :queueIds
                AND    UserOrGroupId =  :UserInfo.getUserId()
            ]) {
                memberOfQueues.add(gm.GroupId);
            }
        }

        for (Discount_Request__c req : newList) {
            Discount_Request__c old = oldMap.get(req.Id);

            // Only validate on Approved/Rejected status transitions
            if (old.Status__c == req.Status__c) continue;
            if (req.Status__c != 'Approved' && req.Status__c != 'Rejected') continue;

            if (!hasPermission) {
                req.addError('No permission to approve/reject.');
                continue;
            }

            // Tier-level enforcement: approver must be a member of the request's
            // owner queue — prevents cross-tier approvals
            if (req.OwnerId != null && String.valueOf(req.OwnerId).startsWith('00G')
                    && !memberOfQueues.contains(req.OwnerId)) {
                req.addError('You are not authorised to approve this tier of request.');
                continue;
            }

            // Rejection comments required
            if (req.Status__c == 'Rejected' && String.isBlank(req.Approver_Comments__c)) {
                req.addError('Comments required for rejection.');
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AFTER UPDATE — Approvals + Audit
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Responds to Approved and Rejected status transitions:
     *                - Stamps Approver__c and Decision_Timestamp__c via a
     *                  secondary update (gated by isProcessingApproval to
     *                  prevent recursion).
     *                - Updates Opportunity.Discount__c when Approved.
     *                - Writes an audit record for every status change.
     *
     *              Validation (permission + tier check + rejection comments)
     *              is handled in handleBeforeUpdate — this method is pure
     *              side-effects only.
     *
     * @param newList Trigger.new from the after-update context.
     * @param oldMap  Trigger.oldMap from the after-update context.
     */
    public static void handleAfterUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {

        List<Discount_Request__c>       updates      = new List<Discount_Request__c>();
        Map<Id, Opportunity>            oppsToUpdate = new Map<Id, Opportunity>();
        List<Discount_Request_Audit__c> audits       = new List<Discount_Request_Audit__c>();

        DateTime now = System.now();

        for (Discount_Request__c req : newList) {

            Discount_Request__c old = oldMap.get(req.Id);

            // Skip records where status did not change
            if (old.Status__c == req.Status__c) continue;

            // Only process terminal approval states
            if (req.Status__c != 'Approved' && req.Status__c != 'Rejected') continue;

            // Stamp the approver and timestamp in a follow-up update.
            // Cannot set these fields in before-update because UserInfo is needed at runtime.
            updates.add(new Discount_Request__c(
                Id                    = req.Id,
                Approver__c           = UserInfo.getUserId(),
                Decision_Timestamp__c = now
            ));

            // Write Discount__c back to the parent Opportunity on approval
            if (req.Status__c == 'Approved') {
                oppsToUpdate.put(req.Opportunity__c,
                    new Opportunity(
                        Id          = req.Opportunity__c,
                        Discount__c = req.Final_Discount__c
                    )
                );
            }

            // Immutable audit record for every approval/rejection
            audits.add(new Discount_Request_Audit__c(
                Discount_Request__c = req.Id,
                Action__c           = req.Status__c,
                Performed_By__c     = UserInfo.getUserId(),
                Comments__c         = req.Approver_Comments__c,
                Timestamp__c        = now
            ));
        }

        if (!updates.isEmpty()) {
            // try-finally ensures the flag is always cleared, even if the inner DML throws
            DiscountRequestHandler.isProcessingApproval = true;
            try {
                update updates;
            } finally {
                DiscountRequestHandler.isProcessingApproval = false;
            }
        }

        if (!oppsToUpdate.isEmpty()) {
            update oppsToUpdate.values();
        }

        if (!audits.isEmpty()) {
            insert audits;
        }
    }
}
