/**
 * @description Thin trigger handler for Discount_Request__c. Delegates all
 *              business logic to DiscountRequestService, keeping the trigger
 *              itself to a single method call per context.
 *
 *              The static flag isProcessingApproval prevents the after-update
 *              handler from re-entering when DiscountRequestService writes
 *              back Approver__c and Decision_Timestamp__c on an approval.
 *
 * @author      Guna Sekhar P.
 */
public with sharing class DiscountRequestHandler {

    /**
     * @description Set to true by DiscountRequestService before it issues the
     *              internal update that stamps Approver__c / Decision_Timestamp__c.
     *              Checked in afterUpdate to skip re-processing that internal DML.
     */
    public static Boolean isProcessingApproval = false;

    /**
     * @description Handles before-insert context: validates the request,
     *              sets Required_Approver_Level__c, and assigns OwnerId to the
     *              correct approver queue.
     * @param newList Trigger.new from the before-insert context.
     */
    public void beforeInsert(List<Discount_Request__c> newList) {
        DiscountRequestService.handleBeforeInsert(newList);
    }

    /**
     * @description Handles before-update context: enforces that rejection
     *              comments are provided when Status__c transitions to Rejected.
     * @param newList Trigger.new from the before-update context.
     * @param oldMap  Trigger.oldMap from the before-update context.
     */
    public void beforeUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {
        DiscountRequestService.handleBeforeUpdate(newList, oldMap);
    }

    /**
     * @description Handles after-insert context: writes audit records, updates
     *              Opportunity.Discount__c for auto-approved requests, deactivates
     *              superseded approved requests, and sends queue notifications.
     * @param newList Trigger.new from the after-insert context.
     */
    public void afterInsert(List<Discount_Request__c> newList) {
        DiscountRequestService.handleAfterInsert(newList);
    }

    /**
     * @description Handles after-update context: stamps the approver, updates
     *              Opportunity.Discount__c, and writes audit records on status
     *              transitions to Approved or Rejected.
     *              Skipped when isProcessingApproval is true to avoid recursion
     *              from the internal approver-stamp DML.
     * @param newList Trigger.new from the after-update context.
     * @param oldMap  Trigger.oldMap from the after-update context.
     */
    public void afterUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {
        if (!isProcessingApproval) {
            DiscountRequestService.handleAfterUpdate(newList, oldMap);
        }
    }
}
