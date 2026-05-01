/**
 * @description Test coverage for DiscountTierSelector, DiscountRequestService,
 *              DiscountRequestHandler, and DiscountRequestController.
 *              Relies on Discount_Approval_Tier__mdt records and Queues being
 *              deployed to the org before running.
 * @author      Guna Sekhar P.
 */
@isTest
public class DiscountRequestTest {

    // ── Test Setup ────────────────────────────────────────────────────────────

    @testSetup
    static void setupTestData() {
        // Account + Opportunity
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Opportunity opp = new Opportunity(
            Name      = 'Test Opportunity',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1),
            Amount    = 100000
        );
        insert opp;

        // Test users — Standard User profile
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User salesRep = buildUser('SalesRep', 'test.salesrep', p.Id);
        User salesManager = buildUser('SalesManager', 'test.salesmanager', p.Id);
        insert new List<User>{ salesRep, salesManager };

        // PermissionSetAssignment and GroupMember are setup objects — runAs() avoids mixed-DML
        PermissionSet ps = [
            SELECT Id FROM PermissionSet WHERE Name = 'Discount_Approver' LIMIT 1
        ];
        Group salesMgrQueue = [
            SELECT Id FROM Group
            WHERE  Type = 'Queue' AND DeveloperName = 'Sales_Manager_Approvals'
            LIMIT  1
        ];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new PermissionSetAssignment(
                AssigneeId      = salesManager.Id,
                PermissionSetId = ps.Id
            );
            insert new GroupMember(
                GroupId       = salesMgrQueue.Id,
                UserOrGroupId = salesManager.Id
            );
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    static User buildUser(String lastName, String emailPrefix, Id profileId) {
        String uniqueSuffix = UserInfo.getOrganizationId();
        return new User(
            FirstName          = 'Test',
            LastName           = lastName,
            Email              = emailPrefix + '@testdiscountorg.com',
            Username           = emailPrefix + '.' + uniqueSuffix + '@testdiscountorg.com',
            Alias              = lastName.left(8),
            ProfileId          = profileId,
            TimeZoneSidKey     = 'America/Los_Angeles',
            LocaleSidKey       = 'en_US',
            EmailEncodingKey   = 'UTF-8',
            LanguageLocaleKey  = 'en_US'
        );
    }

    static Opportunity getTestOpportunity() {
        return [
            SELECT Id, Name, StageName, Discount__c
            FROM   Opportunity
            WHERE  Name = 'Test Opportunity'
            LIMIT  1
        ];
    }

    static User getSalesManager() {
        return [
            SELECT Id FROM User
            WHERE  LastName = 'SalesManager'
            AND    Email    = 'test.salesmanager@testdiscountorg.com'
            LIMIT  1
        ];
    }

    static User getSalesRep() {
        return [
            SELECT Id FROM User
            WHERE  LastName = 'SalesRep'
            AND    Email    = 'test.salesrep@testdiscountorg.com'
            LIMIT  1
        ];
    }

    static Id getQueueId(String developerName) {
        return [
            SELECT Id FROM Group
            WHERE  Type = 'Queue' AND DeveloperName = :developerName
            LIMIT  1
        ].Id;
    }

    // ── 1. Auto-Approve (5%) ──────────────────────────────────────────────────

    @isTest
    static void testAutoApprove() {
        Opportunity opp = getTestOpportunity();

        Test.startTest();
        insert new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 5
        );
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Required_Approver_Level__c, Final_Discount__c
            FROM   Discount_Request__c
            WHERE  Opportunity__c = :opp.Id
            LIMIT  1
        ];
        System.assertEquals('Auto-Approved', result.Status__c,
            'Status should be Auto-Approved for a 5% discount');
        System.assertEquals(5, result.Final_Discount__c,
            'Final_Discount__c should snapshot 5');

        Opportunity oppAfter = [SELECT Discount__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(5, oppAfter.Discount__c,
            'Opportunity.Discount__c should be written back on auto-approval');
    }

    // ── 2. Pending — Sales Manager tier (15%) ─────────────────────────────────

    @isTest
    static void testPendingSalesManager() {
        Opportunity opp     = getTestOpportunity();
        Id          queueId = getQueueId('Sales_Manager_Approvals');

        Test.startTest();
        insert new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Required_Approver_Level__c, Final_Discount__c, OwnerId
            FROM   Discount_Request__c
            WHERE  Opportunity__c = :opp.Id
            LIMIT  1
        ];
        System.assertEquals('Pending', result.Status__c);
        System.assertEquals('Sales Manager', result.Required_Approver_Level__c);
        System.assertEquals(15, result.Final_Discount__c);
        System.assertEquals(queueId, result.OwnerId,
            'Request should be routed to Sales Manager Approvals queue');
    }

    // ── 3. Pending — Director tier (30%) ─────────────────────────────────────

    @isTest
    static void testPendingDirector() {
        Opportunity opp     = getTestOpportunity();
        Id          queueId = getQueueId('Director_Approvals');

        Test.startTest();
        insert new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 30
        );
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Required_Approver_Level__c, OwnerId
            FROM   Discount_Request__c
            WHERE  Opportunity__c = :opp.Id
            LIMIT  1
        ];
        System.assertEquals('Pending', result.Status__c);
        System.assertEquals('Director', result.Required_Approver_Level__c);
        System.assertEquals(queueId, result.OwnerId);
    }

    // ── 4. Pending — CFO tier (45%) ───────────────────────────────────────────

    @isTest
    static void testPendingCFO() {
        Opportunity opp     = getTestOpportunity();
        Id          queueId = getQueueId('CFO_Approvals');

        Test.startTest();
        insert new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 45
        );
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Required_Approver_Level__c, OwnerId
            FROM   Discount_Request__c
            WHERE  Opportunity__c = :opp.Id
            LIMIT  1
        ];
        System.assertEquals('Pending', result.Status__c);
        System.assertEquals('CFO', result.Required_Approver_Level__c);
        System.assertEquals(queueId, result.OwnerId);
    }

    // ── 5. Full approval flow ─────────────────────────────────────────────────

    @isTest
    static void testApprovalFlow() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        // Insert request as system context
        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        System.runAs(salesManager) {
            Discount_Request__c toApprove = [
                SELECT Id, Status__c FROM Discount_Request__c WHERE Id = :req.Id
            ];
            toApprove.Status__c = 'Approved';
            update toApprove;
        }
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Approver__c, Decision_Timestamp__c
            FROM   Discount_Request__c
            WHERE  Id = :req.Id
        ];
        System.assertEquals('Approved', result.Status__c);
        System.assertEquals(salesManager.Id, result.Approver__c,
            'Approver__c should be stamped with Sales Manager Id');
        System.assertNotEquals(null, result.Decision_Timestamp__c,
            'Decision_Timestamp__c should be set');

        Opportunity oppAfter = [SELECT Discount__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(15, oppAfter.Discount__c,
            'Opportunity.Discount__c should be updated on approval');

        List<Discount_Request_Audit__c> audits = [
            SELECT Action__c, Performed_By__c
            FROM   Discount_Request_Audit__c
            WHERE  Discount_Request__c = :req.Id
            ORDER  BY Timestamp__c ASC
        ];
        System.assertEquals(2, audits.size(), 'Two audit records expected: Submitted + Approved');
        System.assertEquals('Submitted', audits[0].Action__c);
        System.assertEquals('Approved',  audits[1].Action__c);
        System.assertEquals(salesManager.Id, audits[1].Performed_By__c);
    }

    // ── 6. Rejection flow with comments ──────────────────────────────────────

    @isTest
    static void testRejectionFlow() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        System.runAs(salesManager) {
            Discount_Request__c toReject = [
                SELECT Id, Status__c FROM Discount_Request__c WHERE Id = :req.Id
            ];
            toReject.Status__c           = 'Rejected';
            toReject.Approver_Comments__c = 'Margin too thin for this deal size.';
            update toReject;
        }
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Approver__c FROM Discount_Request__c WHERE Id = :req.Id
        ];
        System.assertEquals('Rejected', result.Status__c);
        System.assertNotEquals(null, result.Approver__c);

        List<Discount_Request_Audit__c> audits = [
            SELECT Action__c, Comments__c
            FROM   Discount_Request_Audit__c
            WHERE  Discount_Request__c = :req.Id
            ORDER  BY Timestamp__c ASC
        ];
        System.assertEquals(2, audits.size(), 'Two audit records expected: Submitted + Rejected');
        System.assertEquals('Submitted', audits[0].Action__c);
        System.assertEquals('Rejected',  audits[1].Action__c);
        System.assertEquals('Margin too thin for this deal size.', audits[1].Comments__c);
    }

    // ── 7. Reject without comments — must fail ────────────────────────────────

    @isTest
    static void testRejectWithoutComments() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        System.runAs(salesManager) {
            Discount_Request__c toReject = [
                SELECT Id, Status__c FROM Discount_Request__c WHERE Id = :req.Id
            ];
            toReject.Status__c = 'Rejected';
            // Intentionally no Approver_Comments__c
            try {
                update toReject;
                System.assert(false, 'Expected DmlException for missing rejection comments');
            } catch (DmlException e) {
                System.assert(
                    e.getMessage().contains('Comments required for rejection'),
                    'Error should mention required comments. Got: ' + e.getMessage()
                );
            }
        }
        Test.stopTest();
    }

    // ── 8. Block Closed Won / Closed Lost opportunities ───────────────────────

    @isTest
    static void testBlockClosedOpportunity() {
        Opportunity opp = getTestOpportunity();
        opp.StageName   = 'Closed Won';
        update opp;

        Test.startTest();
        try {
            insert new Discount_Request__c(
                Opportunity__c        = opp.Id,
                Requested_Discount__c = 10
            );
            System.assert(false, 'Expected DmlException for Closed Won opportunity');
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('closed Opportunities'),
                'Error should reference closed Opportunities. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    // ── 9. Block duplicate Pending requests on same Opportunity ───────────────

    @isTest
    static void testBlockDuplicatePending() {
        Opportunity opp = getTestOpportunity();

        // First request — Pending
        insert new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );

        Test.startTest();
        try {
            // Second request on the same Opportunity
            insert new Discount_Request__c(
                Opportunity__c        = opp.Id,
                Requested_Discount__c = 20
            );
            System.assert(false, 'Expected DmlException for duplicate Pending request');
        } catch (DmlException e) {
            System.assert(
                e.getMessage().contains('A Pending request already exists'),
                'Error should mention existing Pending request. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    // ── 10. Bulk — 200 requests across 200 Opportunities ─────────────────────

    @isTest
    static void testBulk() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        // 200 Opportunities — one request each avoids the duplicate-pending block
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 200; i++) {
            opps.add(new Opportunity(
                Name      = 'Bulk Opp ' + i,
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addMonths(1),
                Amount    = 10000
            ));
        }
        insert opps;

        // 5% discount → auto-approve tier — no queue SOQL needed, no pending check hit
        List<Discount_Request__c> requests = new List<Discount_Request__c>();
        for (Opportunity opp : opps) {
            requests.add(new Discount_Request__c(
                Opportunity__c        = opp.Id,
                Requested_Discount__c = 5
            ));
        }

        Test.startTest();
        insert requests;
        Test.stopTest();

        List<Discount_Request__c> results = [
            SELECT Status__c
            FROM   Discount_Request__c
            WHERE  Opportunity__c IN :new Map<Id, Opportunity>(opps).keySet()
        ];
        System.assertEquals(200, results.size(), 'All 200 requests must be created');
        for (Discount_Request__c r : results) {
            System.assertEquals('Auto-Approved', r.Status__c,
                'Every bulk request should be Auto-Approved');
        }
    }

    // ── 11. Unauthorised approval — no custom permission ──────────────────────

    @isTest
    static void testUnauthorisedApproval() {
        Opportunity opp      = getTestOpportunity();
        User        salesRep = getSalesRep();

        // Insert as system
        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        Boolean exceptionThrown = false;
        System.runAs(salesRep) {
            Discount_Request__c toApprove = [
                SELECT Id, Status__c FROM Discount_Request__c WHERE Id = :req.Id
            ];
            toApprove.Status__c = 'Approved';
            try {
                update toApprove;
                System.assert(false, 'Expected exception for unauthorised approval attempt');
            } catch (DmlException e) {
                // addError in the trigger surfaces as DmlException — message is 'No permission to approve/reject.'
                exceptionThrown = true;
            }
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'DmlException must be thrown for unauthorised approval');
        Discount_Request__c stillPending = [SELECT Status__c FROM Discount_Request__c WHERE Id = :req.Id];
        System.assertEquals('Pending', stillPending.Status__c,
            'Request must remain Pending after unauthorised approval attempt');
    }

    // ── 12. Controller — getDiscountRequests ──────────────────────────────────

    @isTest
    static void testControllerGetDiscountRequests() {
        Opportunity opp = getTestOpportunity();
        insert new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );

        Test.startTest();
        List<Discount_Request__c> results =
            DiscountRequestController.getDiscountRequests(opp.Id);
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return 1 request for the opportunity');
        System.assertEquals(15, results[0].Requested_Discount__c);
    }

    // ── 13. Controller — createDiscountRequest happy path ─────────────────────

    @isTest
    static void testControllerCreateDiscountRequest() {
        Opportunity opp = getTestOpportunity();

        Test.startTest();
        DiscountRequestController.createDiscountRequest(opp.Id, 15, 'Test reason');
        Test.stopTest();

        List<Discount_Request__c> results = [
            SELECT Requested_Discount__c, Reason__c
            FROM   Discount_Request__c
            WHERE  Opportunity__c = :opp.Id
        ];
        System.assertEquals(1, results.size());
        System.assertEquals(15, results[0].Requested_Discount__c);
        System.assertEquals('Test reason', results[0].Reason__c);
    }

    // ── 14. Controller — createDiscountRequest validations ────────────────────

    @isTest
    static void testControllerCreateValidations() {
        Opportunity opp = getTestOpportunity();

        Test.startTest();

        // Null opportunityId
        try {
            DiscountRequestController.createDiscountRequest(null, 15, '');
            System.assert(false, 'Expected AuraHandledException for null opportunityId');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }

        // Null discount
        try {
            DiscountRequestController.createDiscountRequest(opp.Id, null, '');
            System.assert(false, 'Expected AuraHandledException for null discount');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }

        // Discount out of range
        try {
            DiscountRequestController.createDiscountRequest(opp.Id, 110, '');
            System.assert(false, 'Expected AuraHandledException for discount > 100');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage() != null);
        }

        Test.stopTest();
    }

    // ── 15. Controller — approveRequest happy path ────────────────────────────

    @isTest
    static void testControllerApproveRequest() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        System.runAs(salesManager) {
            DiscountRequestController.approveRequest(req.Id);
        }
        Test.stopTest();

        Discount_Request__c result = [SELECT Status__c FROM Discount_Request__c WHERE Id = :req.Id];
        System.assertEquals('Approved', result.Status__c);
    }

    // ── 16. Controller — approveRequest already actioned ─────────────────────

    @isTest
    static void testControllerApproveAlreadyActioned() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        System.runAs(salesManager) {
            DiscountRequestController.approveRequest(req.Id);
        }

        Test.startTest();
        System.runAs(salesManager) {
            try {
                DiscountRequestController.approveRequest(req.Id);
                System.assert(false, 'Expected AuraHandledException for already-approved request');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage() != null);
            }
        }
        Test.stopTest();
    }

    // ── 17. Controller — rejectRequest happy path ─────────────────────────────

    @isTest
    static void testControllerRejectRequest() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        System.runAs(salesManager) {
            DiscountRequestController.rejectRequest(req.Id, 'Margin too thin.');
        }
        Test.stopTest();

        Discount_Request__c result = [
            SELECT Status__c, Approver_Comments__c FROM Discount_Request__c WHERE Id = :req.Id
        ];
        System.assertEquals('Rejected', result.Status__c);
        System.assertEquals('Margin too thin.', result.Approver_Comments__c);
    }

    // ── 18. Controller — rejectRequest blank comments ─────────────────────────

    @isTest
    static void testControllerRejectBlankComments() {
        Opportunity opp          = getTestOpportunity();
        User        salesManager = getSalesManager();

        Discount_Request__c req = new Discount_Request__c(
            Opportunity__c        = opp.Id,
            Requested_Discount__c = 15
        );
        insert req;

        Test.startTest();
        System.runAs(salesManager) {
            try {
                DiscountRequestController.rejectRequest(req.Id, '   ');
                System.assert(false, 'Expected AuraHandledException for blank comments');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage() != null,
                    'AuraHandledException must be thrown for blank comments');
            }
        }
        Test.stopTest();
    }

    // ── 19. Controller — permission checks ───────────────────────────────────

    @isTest
    static void testControllerPermissionChecks() {
        User salesRep     = getSalesRep();
        User salesManager = getSalesManager();

        Test.startTest();

        // Sales rep has no permission sets
        System.runAs(salesRep) {
            System.assertEquals(false, DiscountRequestController.hasApproverPermission(),
                'Sales rep must not have approver permission');
            System.assertEquals(false, DiscountRequestController.hasRequesterPermission(),
                'Sales rep must not have requester permission');
        }

        // Sales manager has Discount_Approver permission set
        System.runAs(salesManager) {
            System.assertEquals(true, DiscountRequestController.hasApproverPermission(),
                'Sales manager must have approver permission');
        }

        Test.stopTest();
    }
}