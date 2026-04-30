/**
 * @description Apex REST endpoint — allows external systems to create a
 *              Discount Request without access to the LWC.
 *
 * POST /services/apexrest/discount-requests/v1
 *
 * Request body (JSON):
 *   {
 *     "opportunityId" : "006xx...",
 *     "discount"      : 15.5,
 *     "reason"        : "Strategic deal — competitive pricing needed."
 *   }
 *
 * Responses:
 *   201  { "requestId", "requestName", "status", "message" }
 *   400  { "message" }   — validation failure
 *   500  { "message" }   — unexpected error
 */
@RestResource(urlMapping='/discount-requests/v1')
global with sharing class DiscountRequestResource {

    global class CreateRequestBody {
        global Id      opportunityId;
        global Decimal discount;
        global String  reason;
    }

    global class ApiResponse {
        global Id     requestId;
        global String requestName;
        global String status;
        global String message;
    }

    @HttpPost
    global static void createDiscountRequest() {

        RestResponse res = RestContext.response;
        ApiResponse  body = new ApiResponse();

        try {
            CreateRequestBody payload = (CreateRequestBody) JSON.deserialize(
                RestContext.request.requestBody.toString(),
                CreateRequestBody.class
            );

            // ── Validation ───────────────────────────────────────────────────
            if (payload.opportunityId == null) {
                respond(res, 400, null, body, 'opportunityId is required.');
                return;
            }
            if (payload.discount == null || payload.discount < 0 || payload.discount > 100) {
                respond(res, 400, null, body, 'discount must be a number between 0 and 100.');
                return;
            }

            // ── Insert ───────────────────────────────────────────────────────
            Discount_Request__c dr = new Discount_Request__c(
                Opportunity__c        = payload.opportunityId,
                Requested_Discount__c = payload.discount,
                Reason__c             = payload.reason
            );
            insert as user dr;

            // Re-query — trigger sets Name, Status__c, Required_Approver_Level__c
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
            respond(res, 400, null, body, e.getDmlMessage(0));
        } catch (Exception e) {
            respond(res, 500, null, body, e.getMessage());
        }
    }

    // ── Helper ───────────────────────────────────────────────────────────────

    private static void respond(
        RestResponse    res,
        Integer         statusCode,
        ApiResponse     data,
        ApiResponse     fallback,
        String          message
    ) {
        res.addHeader('Content-Type', 'application/json');
        res.statusCode = statusCode;

        ApiResponse payload = data != null ? data : (fallback != null ? fallback : new ApiResponse());
        payload.message = message;
        res.responseBody = Blob.valueOf(JSON.serializePretty(payload));
    }
}
