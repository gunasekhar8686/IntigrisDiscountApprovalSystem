/**
 * @description AuraEnabled controller for the discountRequestPanel LWC.
 *              All methods run with sharing and enforce FLS via WITH USER_MODE.
 *              Every method is wrapped in try/catch and re-throws
 *              AuraHandledException so the LWC receives a clean error message.
 * @author      Guna Sekhar P.
 */
public with sharing class DiscountRequestController {

    // ─── Queries ─────────────────────────────────────────────────────────────

    /**
     * @description Returns all Discount Requests for the given Opportunity,
     *              newest first. Cached by the platform until a data change
     *              invalidates it.
     */
    @AuraEnabled(cacheable=true)
    public static List<Discount_Request__c> getDiscountRequests(Id opportunityId) {
        try {
            return [
                SELECT Id, Name,
                       Requested_Discount__c, Status__c,
                       Required_Approver_Level__c, Final_Discount__c,
                       Approver__c, Approver__r.Name,
                       Decision_Timestamp__c, Approver_Comments__c,
                       Reason__c, Is_Active__c, CreatedDate
                FROM   Discount_Request__c
                WHERE  Opportunity__c = :opportunityId
                WITH   USER_MODE
                ORDER  BY CreatedDate DESC
            ];
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ─── Mutations ───────────────────────────────────────────────────────────

    /**
     * @description Creates a new Discount Request for the given Opportunity.
     *              Tier resolution, queue routing, and auto-approval are handled
     *              by the trigger.
     */
    @AuraEnabled
    public static void createDiscountRequest(
        Id      opportunityId,
        Decimal discount,
        String  reason
    ) {
        try {
            if (opportunityId == null) {
                throw new AuraHandledException('Opportunity Id is required.');
            }
            if (discount == null || discount < 0 || discount > 100) {
                throw new AuraHandledException(
                    'Requested Discount must be a number between 0 and 100.'
                );
            }

            Discount_Request__c req = new Discount_Request__c(
                Opportunity__c        = opportunityId,
                Requested_Discount__c = discount,
                Reason__c             = reason
            );
            insert as user req;
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Sets Status to Approved. The trigger stamps Approver__c,
     *              Decision_Timestamp__c, and updates Opportunity.Discount__c.
     */
    @AuraEnabled
    public static void approveRequest(Id requestId) {
        try {
            // FOR UPDATE locks the row — WITH USER_MODE incompatible with FOR UPDATE
            Discount_Request__c req = [
                SELECT Id, Status__c
                FROM   Discount_Request__c
                WHERE  Id = :requestId
                FOR UPDATE
            ];
            if (req.Status__c != 'Pending') {
                throw new AuraHandledException(
                    'This request has already been ' + req.Status__c.toLowerCase() + '.'
                );
            }
            req.Status__c = 'Approved';
            update as user req;
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Sets Status to Rejected with mandatory comments.
     *              The trigger stamps Approver__c and Decision_Timestamp__c.
     */
    @AuraEnabled
    public static void rejectRequest(Id requestId, String comments) {
        try {
            if (String.isBlank(comments)) {
                throw new AuraHandledException(
                    'Comments are required when rejecting a discount request.'
                );
            }
            // FOR UPDATE locks the row — WITH USER_MODE incompatible with FOR UPDATE
            Discount_Request__c req = [
                SELECT Id, Status__c
                FROM   Discount_Request__c
                WHERE  Id = :requestId
                FOR UPDATE
            ];
            if (req.Status__c != 'Pending') {
                throw new AuraHandledException(
                    'This request has already been ' + req.Status__c.toLowerCase() + '.'
                );
            }
            req.Status__c            = 'Rejected';
            req.Approver_Comments__c = comments;
            update as user req;
        } catch (AuraHandledException e) {
            throw e;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ─── Permission check ─────────────────────────────────────────────────────

    /**
     * @description Returns true if the running user holds the
     *              Approve_Discount_Request custom permission.
     *              Used by the LWC to show/hide approve and reject buttons.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasApproverPermission() {
        try {
            return FeatureManagement.checkPermission('Approve_Discount_Request');
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * @description Returns true if the running user holds the
     *              Submit_Discount_Request custom permission.
     *              Used by the LWC to show/hide the New Discount Request button.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasRequesterPermission() {
        try {
            return FeatureManagement.checkPermission('Submit_Discount_Request');
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}