@isTest
public class DiscountRequestAPITest {

    @testSetup
    static void setup() {
        Account acc = new Account(Name = 'REST Test Account');
        insert acc;
        insert new Opportunity(
            Name      = 'REST Test Opp',
            AccountId = acc.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1),
            Amount    = 50000
        );
    }

    static Opportunity getOpp() {
        return [SELECT Id FROM Opportunity WHERE Name = 'REST Test Opp' LIMIT 1];
    }

    static void setRequest(String body) {
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI    = '/services/apexrest/discount-requests/v1';
        RestContext.request.httpMethod    = 'POST';
        RestContext.request.requestBody   = Blob.valueOf(body);
        RestContext.request.addHeader('Content-Type', 'application/json');
    }

    // ── 1. Happy path — Pending tier ─────────────────────────────────────────

    @isTest
    static void testCreatePending() {
        Opportunity opp = getOpp();
        setRequest('{"opportunityId":"' + opp.Id + '","discount":15,"reason":"Test"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode);
        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assertEquals('Pending', resp.get('status'));
        System.assertEquals('Discount request created successfully.', resp.get('message'));
        System.assertNotEquals(null, resp.get('requestId'));
        System.assertNotEquals(null, resp.get('requestName'));
    }

    // ── 2. Happy path — Auto-approved tier ───────────────────────────────────

    @isTest
    static void testCreateAutoApproved() {
        Opportunity opp = getOpp();
        setRequest('{"opportunityId":"' + opp.Id + '","discount":5,"reason":"Small deal"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode);
        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assertEquals('Auto-Approved', resp.get('status'));
    }

    // ── 3. Missing opportunityId → 400 ───────────────────────────────────────

    @isTest
    static void testMissingOpportunityId() {
        setRequest('{"discount":15,"reason":"No opp"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assert(
            ((String) resp.get('message')).contains('opportunityId is required'),
            'Got: ' + resp.get('message')
        );
    }

    // ── 4. Invalid discount → 400 ────────────────────────────────────────────

    @isTest
    static void testInvalidDiscount() {
        Opportunity opp = getOpp();
        setRequest('{"opportunityId":"' + opp.Id + '","discount":150}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ── 5. DML error (closed opportunity) → 400 ──────────────────────────────

    @isTest
    static void testClosedOpportunity() {
        Opportunity opp = getOpp();
        opp.StageName = 'Closed Won';
        update opp;

        setRequest('{"opportunityId":"' + opp.Id + '","discount":15,"reason":"Too late"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode);
    }
}
