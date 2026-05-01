/**
 * @description Selector for Discount_Approval_Tier__mdt. Caches all records and
 *              resolved Queue Ids in static variables to avoid repeated queries
 *              within a single transaction.
 * @author      Guna Sekhar P.
 */
public without sharing class DiscountTierSelector {

    private static List<Discount_Approval_Tier__mdt> cachedTiers;
    private static Map<String, Id> cachedQueueIds = new Map<String, Id>();

    // ─── Tier resolution ────────────────────────────────────────────────────

    /**
     * @description Returns all tiers, loading from SOQL on first call.
     */
    private static List<Discount_Approval_Tier__mdt> getAllTiers() {
        if (cachedTiers == null) {
            // WITH USER_MODE is not supported on Custom Metadata Type queries —
            // CMDT is setup data, accessible to all users regardless of profile
            cachedTiers = [
                SELECT DeveloperName, Label,
                       Min_Discount__c, Max_Discount__c,
                       Approver_Level__c, Auto_Approve__c, Queue_DeveloperName__c
                FROM   Discount_Approval_Tier__mdt
                ORDER  BY Min_Discount__c ASC
            ];
        }
        return cachedTiers;
    }

    /**
     * @description Returns the first tier whose Min/Max range contains the given
     *              discount percentage. Returns null if no tier matches.
     */
    public static Discount_Approval_Tier__mdt getMatchingTier(Decimal discountPct) {
        for (Discount_Approval_Tier__mdt tier : getAllTiers()) {
            if (discountPct >= tier.Min_Discount__c && discountPct <= tier.Max_Discount__c) {
                return tier;
            }
        }
        return null;
    }

    // ─── Queue Id resolution ─────────────────────────────────────────────────

    /**
     * @description Resolves Queue Ids for the provided set of DeveloperNames.
     *              Results are merged into the static cache so subsequent calls
     *              within the same transaction never re-query.
     *
     * @param  developerNames  Set of Queue DeveloperName values to resolve.
     * @return                 Map of DeveloperName → Queue Id for all known queues.
     */
    public static Map<String, Id> resolveQueueIds(Set<String> developerNames) {
        Set<String> toQuery = new Set<String>();
        for (String devName : developerNames) {
            if (String.isNotBlank(devName) && !cachedQueueIds.containsKey(devName)) {
                toQuery.add(devName);
            }
        }

        if (!toQuery.isEmpty()) {
            for (Group q : [
                SELECT Id, DeveloperName
                FROM   Group
                WHERE  Type = 'Queue'
                AND    DeveloperName IN :toQuery
                WITH   USER_MODE
            ]) {
                cachedQueueIds.put(q.DeveloperName, q.Id);
            }
        }

        return cachedQueueIds;
    }
}