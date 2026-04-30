/**
 * @description Test coverage for DiscountRequestAPI (Apex REST endpoint).
 *              Uses RestContext.request / RestContext.response to simulate
 *              inbound HTTP calls without spinning up a real HTTP server.
 *
 *              Relies on Discount_Approval_Tier__mdt records being deployed
 *              to the org before running (Auto Approve tier for 0–9.99 %,
 *              Sales Manager tier for 10–24.99 %).
 *
 * @author      Guna Sekhar P.
 */
@isTest
public class DiscountRequestAPITest {

    // ── Test Setup ────────────────────────────────────────────────────────────

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

    // ── Helpers ───────────────────────────────────────────────────────────────

    static Opportunity getOpp() {
        return [SELECT Id FROM Opportunity WHERE Name = 'REST Test Opp' LIMIT 1];
    }

    /**
     * @description Configures RestContext with a simulated POST request body
     *              so DiscountRequestAPI.createDiscountRequest() can be called
     *              directly in the test without an actual HTTP request.
     */
    static void setRequest(String body) {
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI  = '/services/apexrest/discount-requests/v1';
        RestContext.request.httpMethod  = 'POST';
        RestContext.request.requestBody = Blob.valueOf(body);
        RestContext.request.addHeader('Content-Type', 'application/json');
    }

    // ── 1. Happy path — Pending tier (15%) ───────────────────────────────────

    @isTest
    static void testCreatePending() {
        Opportunity opp = getOpp();
        setRequest('{"opportunityId":"' + opp.Id + '","discount":15,"reason":"Test"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode,
            'Expected 201 for a valid Pending request');
        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assertEquals('Pending', resp.get('status'),
            'Status should be Pending for a 15% discount');
        System.assertEquals('Discount request created successfully.', resp.get('message'));
        System.assertNotEquals(null, resp.get('requestId'),   'requestId must be populated');
        System.assertNotEquals(null, resp.get('requestName'), 'requestName must be populated');
    }

    // ── 2. Happy path — Auto-approved tier (5%) ──────────────────────────────

    @isTest
    static void testCreateAutoApproved() {
        Opportunity opp = getOpp();
        setRequest('{"opportunityId":"' + opp.Id + '","discount":5,"reason":"Small deal"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(201, RestContext.response.statusCode,
            'Expected 201 for a valid Auto-Approved request');
        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assertEquals('Auto-Approved', resp.get('status'),
            'Status should be Auto-Approved for a 5% discount');
    }

    // ── 3. Missing opportunityId → 400 ───────────────────────────────────────

    @isTest
    static void testMissingOpportunityId() {
        setRequest('{"discount":15,"reason":"No opp"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Expected 400 when opportunityId is missing');
        Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        System.assert(
            ((String) resp.get('message')).contains('opportunityId is required'),
            'Message should reference missing opportunityId. Got: ' + resp.get('message')
        );
    }

    // ── 4. Discount out of range → 400 ───────────────────────────────────────

    @isTest
    static void testInvalidDiscount() {
        Opportunity opp = getOpp();
        setRequest('{"opportunityId":"' + opp.Id + '","discount":150}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Expected 400 for discount > 100');
    }

    // ── 5. Closed opportunity → 400 ──────────────────────────────────────────

    @isTest
    static void testClosedOpportunity() {
        Opportunity opp = getOpp();
        opp.StageName = 'Closed Won';
        update opp;

        setRequest('{"opportunityId":"' + opp.Id + '","discount":15,"reason":"Too late"}');

        Test.startTest();
        DiscountRequestAPI.createDiscountRequest();
        Test.stopTest();

        System.assertEquals(400, RestContext.response.statusCode,
            'Expected 400 when Opportunity is closed');
    }
}
