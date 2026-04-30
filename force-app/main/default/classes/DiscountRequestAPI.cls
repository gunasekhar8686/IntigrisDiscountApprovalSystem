/**
 * @description Apex REST endpoint that allows external systems (ERP, CPQ tools,
 *              integrations) to create a Discount_Request__c without access to
 *              the Salesforce UI or LWC.
 *
 *              The same trigger pipeline fires on insert — tier routing,
 *              auto-approval, duplicate guard, and queue email notifications all
 *              behave identically to a request submitted via the LWC.
 *
 * Endpoint  : POST /services/apexrest/discount-requests/v1
 *
 * Request body (JSON):
 *   {
 *     "opportunityId" : "006xx...",   // required
 *     "discount"      : 15.5,         // required, 0–100
 *     "reason"        : "..."         // optional
 *   }
 *
 * Response codes:
 *   201  Request created — body contains requestId, requestName, status, message
 *   400  Validation failure or DML error (e.g. closed opp, duplicate pending)
 *   500  Unexpected server error
 *
 * @author Guna Sekhar P.
 */
@RestResource(urlMapping='/discount-requests/v1')
global with sharing class DiscountRequestAPI {

    /**
     * @description Deserialised representation of the POST request body.
     */
    global class CreateRequestBody {
        global Id      opportunityId;
        global Decimal discount;
        global String  reason;
    }

    /**
     * @description Serialised response body returned for all outcomes.
     *              requestId, requestName, and status are null on error responses.
     */
    global class ApiResponse {
        global Id     requestId;
        global String requestName;
        global String status;
        global String message;
    }

    /**
     * @description Creates a Discount Request from an external system payload.
     *              Validates required fields and discount range, inserts the record
     *              as the running user (insert as user), then re-queries to return
     *              trigger-set fields (Name, Status__c) in the response.
     */
    @HttpPost
    global static void createDiscountRequest() {

        RestResponse res  = RestContext.response;
        ApiResponse  body = new ApiResponse();

        try {
            // Deserialise the raw JSON body into the typed inner class
            CreateRequestBody payload = (CreateRequestBody) JSON.deserialize(
                RestContext.request.requestBody.toString(),
                CreateRequestBody.class
            );

            // ── Input validation ─────────────────────────────────────────────
            if (payload.opportunityId == null) {
                respond(res, 400, null, body, 'opportunityId is required.');
                return;
            }
            if (payload.discount == null || payload.discount < 0 || payload.discount > 100) {
                respond(res, 400, null, body, 'discount must be a number between 0 and 100.');
                return;
            }

            // ── Insert ───────────────────────────────────────────────────────
            // insert as user enforces FLS and sharing rules for the connected app user
            Discount_Request__c dr = new Discount_Request__c(
                Opportunity__c        = payload.opportunityId,
                Requested_Discount__c = payload.discount,
                Reason__c             = payload.reason
            );
            insert as user dr;

            // Re-query after insert — trigger sets Name, Status__c, Required_Approver_Level__c
            dr = [
                SELECT Id, Name, Status__c
                FROM   Discount_Request__c
                WHERE  Id = :dr.Id
            ];

            body.requestId   = dr.Id;
            body.requestName = dr.Name;
            body.status      = dr.Status__c;
            respond(res, 201, body, null, 'Discount request created successfully.');

        } catch (DmlException e) {
            // Trigger addError messages surface here — e.g. closed opportunity, duplicate pending
            respond(res, 400, null, body, e.getDmlMessage(0));
        } catch (Exception e) {
            respond(res, 500, null, body, e.getMessage());
        }
    }

    // ── Helper ───────────────────────────────────────────────────────────────

    /**
     * @description Sets the HTTP status code, serialises the response payload to
     *              JSON, and writes it to the RestResponse body.
     *
     * @param res        The current RestContext response object.
     * @param statusCode HTTP status code to set (201, 400, 500).
     * @param data       Populated ApiResponse for success paths; null on error.
     * @param fallback   Empty ApiResponse shell used when data is null.
     * @param message    Human-readable message to include in every response.
     */
    private static void respond(
        RestResponse res,
        Integer      statusCode,
        ApiResponse  data,
        ApiResponse  fallback,
        String       message
    ) {
        res.addHeader('Content-Type', 'application/json');
        res.statusCode = statusCode;

        ApiResponse payload = data != null ? data : (fallback != null ? fallback : new ApiResponse());
        payload.message      = message;
        res.responseBody     = Blob.valueOf(JSON.serializePretty(payload));
    }
}
