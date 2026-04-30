public without sharing class DiscountRequestHandler {

    public static Boolean isProcessingApproval = false;

    public void beforeInsert(List<Discount_Request__c> newList) {
        DiscountRequestService.handleBeforeInsert(newList);
    }

    public void beforeUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {
        DiscountRequestService.handleBeforeUpdate(newList, oldMap);
    }

    public void afterInsert(List<Discount_Request__c> newList) {
        DiscountRequestService.handleAfterInsert(newList);
    }

    public void afterUpdate(
        List<Discount_Request__c> newList,
        Map<Id, Discount_Request__c> oldMap
    ) {
        if (!isProcessingApproval) {
            DiscountRequestService.handleAfterUpdate(newList, oldMap);
        }
    }
}