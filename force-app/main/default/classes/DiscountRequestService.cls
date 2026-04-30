public without sharing class DiscountRequestService {

    // ─────────────────────────────────────────────
    // BEFORE INSERT (Validation + Field Setting)
    // ─────────────────────────────────────────────
    public static void handleBeforeInsert(List<Discount_Request__c> requests) {

        Set<Id> oppIds = new Set<Id>();
        for (Discount_Request__c req : requests) {
            if (req.Opportunity__c != null) {
                oppIds.add(req.Opportunity__c);
            }
        }

        // Query Opportunities
        Map<Id, Opportunity> oppsMap = new Map<Id, Opportunity>([
            SELECT Id, IsClosed
            FROM Opportunity
            WHERE Id IN :oppIds
        ]);

        // Existing pending requests (NO self issue now)
        Map<Id, Discount_Request__c> pendingByOpp = new Map<Id, Discount_Request__c>();
        // WITH USER_MODE is incompatible with FOR UPDATE — omitted intentionally here
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

        // Preload queue IDs in bulk (DiscountTierSelector caches tier lookups internally)
        Set<String> queueDevNames = new Set<String>();
        for (Discount_Request__c req : requests) {
            Discount_Approval_Tier__mdt tier =
                DiscountTierSelector.getMatchingTier(req.Requested_Discount__c);
            if (tier != null && !tier.Auto_Approve__c && String.isNotBlank(tier.Queue_DeveloperName__c)) {
                queueDevNames.add(tier.Queue_DeveloperName__c);
            }
        }
        Map<String, Id> queueIds = DiscountTierSelector.resolveQueueIds(queueDevNames);

        // Main processing
        for (Discount_Request__c req : requests) {

            Opportunity opp = oppsMap.get(req.Opportunity__c);

            if (opp == null) {
                req.addError('Invalid Opportunity.');
                continue;
            }

            // Closed check — IsClosed covers all closed stages, not just named ones
            if (opp.IsClosed) {
                req.addError('Cannot create discount request on closed Opportunities.');
                continue;
            }

            // Duplicate check
            if (pendingByOpp.containsKey(req.Opportunity__c)) {
                req.addError('A Pending request already exists.');
                continue;
            }

            // Each call is cached — no extra SOQL
            Discount_Approval_Tier__mdt tier =
                DiscountTierSelector.getMatchingTier(req.Requested_Discount__c);

            if (tier == null) {
                req.addError('No approval tier configured.');
                continue;
            }

            // Snapshot
            req.Required_Approver_Level__c = tier.Approver_Level__c;
            req.Final_Discount__c = req.Requested_Discount__c;
            req.Is_Active__c = true;

            if (tier.Auto_Approve__c) {
                req.Status__c = 'Auto-Approved';
                req.Required_Approver_Level__c='Auto Approve';
                req.Decision_Timestamp__c=system.now();
            } else {
                req.Status__c = 'Pending';

                Id queueId = queueIds.get(tier.Queue_DeveloperName__c);
                if (queueId != null) {
                    req.OwnerId = queueId;
                }
            }
        }
    }

    // ─────────────────────────────────────────────
    // AFTER INSERT (Side Effects)
    // ─────────────────────────────────────────────
    public static void handleAfterInsert(List<Discount_Request__c> requests) {

        Set<Id> oppIds       = new Set<Id>();
        Set<Id> newReqIds    = new Set<Id>();
        Map<Id, Opportunity> oppsToUpdate   = new Map<Id, Opportunity>();
        List<Discount_Request_Audit__c> audits = new List<Discount_Request_Audit__c>();
        DateTime now = System.now();

        for (Discount_Request__c req : requests) {
            if (req.Opportunity__c != null) oppIds.add(req.Opportunity__c);
            newReqIds.add(req.Id);

            // Audit on every insert — Submitted or Auto-Approved
            audits.add(new Discount_Request_Audit__c(
                Discount_Request__c = req.Id,
                Action__c           = req.Status__c == 'Auto-Approved' ? 'Auto-Approved' : 'Submitted',
                Performed_By__c     = UserInfo.getUserId(),
                Comments__c         = req.Reason__c,
                Timestamp__c        = now
            ));

            // Update Opportunity immediately for auto-approvals
            if (req.Status__c == 'Auto-Approved') {
                oppsToUpdate.put(req.Opportunity__c,
                    new Opportunity(Id = req.Opportunity__c, Discount__c = req.Final_Discount__c)
                );
            }
        }

        // Stacked discount — deactivate any prior Approved/Auto-Approved requests
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

        // Notify queue members for all Pending requests (bulk-safe, single sendEmail call)
        List<Discount_Request__c> pendingInserts = new List<Discount_Request__c>();
        for (Discount_Request__c req : requests) {
            if (req.Status__c == 'Pending') pendingInserts.add(req);
        }
        if (!pendingInserts.isEmpty()) {
            sendQueueNotifications(pendingInserts);
        }
    }

    // ─────────────────────────────────────────────
    // EMAIL NOTIFICATIONS (bulk-safe)
    // ─────────────────────────────────────────────
    private static void sendQueueNotifications(List<Discount_Request__c> pendingRequests) {

        // 1. Collect distinct queue owner IDs and opp IDs
        Set<Id> queueOwnerIds = new Set<Id>();
        Set<Id> oppIds        = new Set<Id>();
        for (Discount_Request__c req : pendingRequests) {
            if (req.OwnerId != null) queueOwnerIds.add(req.OwnerId);
            if (req.Opportunity__c != null) oppIds.add(req.Opportunity__c);
        }

        // 2. Queue group records → queue email address
        Map<Id, Group> queuesById = new Map<Id, Group>([
            SELECT Id, Email FROM Group WHERE Id IN :queueOwnerIds AND Type = 'Queue'
        ]);

        // 3. All members across all queues → user IDs
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

        // 4. User email addresses
        Map<Id, String> emailByUserId = new Map<Id, String>();
        for (User u : [SELECT Id, Email FROM User WHERE Id IN :memberUserIds AND IsActive = true]) {
            emailByUserId.put(u.Id, u.Email);
        }

        // 5. Opportunity names
        Map<Id, Opportunity> oppsById = new Map<Id, Opportunity>([
            SELECT Id, Name FROM Opportunity WHERE Id IN :oppIds
        ]);

        String baseUrl = System.URL.getOrgDomainUrl().toExternalForm();

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Discount_Request__c req : pendingRequests) {

            Group queue       = queuesById.get(req.OwnerId);
            Opportunity opp   = oppsById.get(req.Opportunity__c);
            String oppName    = opp != null ? opp.Name : req.Opportunity__c;
            String oppLink    = baseUrl + '/lightning/r/Opportunity/' + req.Opportunity__c + '/view';

            String subject = 'Action Required: Discount Approval — ' + oppName + ' (' + req.Name + ')';

            String reasonRow = String.isNotBlank(req.Reason__c)
                ? '<tr><td style="padding:6px 12px;color:#555;width:160px;"><b>Reason</b></td><td style="padding:6px 12px;">' + req.Reason__c + '</td></tr>'
                : '';

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

            // a) Queue group email (if configured)
            if (queue != null && String.isNotBlank(queue.Email)) {
                System.debug('### Adding queue email: ' + queue.Email);
                Messaging.SingleEmailMessage queueMsg = new Messaging.SingleEmailMessage();
                queueMsg.setToAddresses(new List<String>{ queue.Email });
                queueMsg.setSubject(subject);
                queueMsg.setHtmlBody(htmlBody);
                queueMsg.setSaveAsActivity(false);
                emails.add(queueMsg);
            }

            // b) Individual members
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

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails, false);
        }
    }

    // ─────────────────────────────────────────────
    // BEFORE UPDATE (Validation)
    // ─────────────────────────────────────────────
    public static void handleBeforeUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {
        for (Discount_Request__c req : newList) {
            Discount_Request__c old = oldMap.get(req.Id);

            if (old.Status__c != req.Status__c &&
                req.Status__c == 'Rejected' &&
                String.isBlank(req.Approver_Comments__c)) {

                req.addError('Comments required for rejection.');
            }
        }
    }

    // ─────────────────────────────────────────────
    // AFTER UPDATE (Approvals + Audit)
    // ─────────────────────────────────────────────
    public static void handleAfterUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {

        List<Discount_Request__c> updates = new List<Discount_Request__c>();
        Map<Id, Opportunity> oppsToUpdate = new Map<Id, Opportunity>();
        List<Discount_Request_Audit__c> audits = new List<Discount_Request_Audit__c>();

        DateTime now = System.now();

        for (Discount_Request__c req : newList) {

            Discount_Request__c old = oldMap.get(req.Id);

            if (old.Status__c == req.Status__c) continue;

            if (req.Status__c != 'Approved' && req.Status__c != 'Rejected') continue;

            // Stamp approver
            updates.add(new Discount_Request__c(
                Id = req.Id,
                Approver__c = UserInfo.getUserId(),
                Decision_Timestamp__c = now
            ));

            // Update Opportunity
            if (req.Status__c == 'Approved') {
                oppsToUpdate.put(req.Opportunity__c,
                    new Opportunity(
                        Id = req.Opportunity__c,
                        Discount__c = req.Final_Discount__c
                    )
                );
            }

            // Audit
            audits.add(new Discount_Request_Audit__c(
                Discount_Request__c = req.Id,
                Action__c = req.Status__c,
                Performed_By__c = UserInfo.getUserId(),
                Comments__c = req.Approver_Comments__c,
                Timestamp__c = now
            ));
        }

        if (!updates.isEmpty()) {
            if (!FeatureManagement.checkPermission('Approve_Discount_Request')) {
                throw new AuraHandledException('No permission to approve/reject.');
            }
            DiscountRequestHandler.isProcessingApproval = true;
            update updates;
            DiscountRequestHandler.isProcessingApproval = false;
        }

        if (!oppsToUpdate.isEmpty()) {
            update oppsToUpdate.values();
        }

        if (!audits.isEmpty()) {
            insert audits;
        }
    }
}