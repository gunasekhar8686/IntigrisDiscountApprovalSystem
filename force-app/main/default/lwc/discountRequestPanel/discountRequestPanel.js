import { LightningElement, api, wire } from 'lwc';
import { refreshApex }                from '@salesforce/apex';
import { ShowToastEvent }             from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue }   from 'lightning/uiRecordApi';
import OPP_IS_CLOSED                  from '@salesforce/schema/Opportunity.IsClosed';

import getDiscountRequests    from '@salesforce/apex/DiscountRequestController.getDiscountRequests';
import hasApproverPermission  from '@salesforce/apex/DiscountRequestController.hasApproverPermission';
import hasRequesterPermission from '@salesforce/apex/DiscountRequestController.hasRequesterPermission';
import createDiscountRequest  from '@salesforce/apex/DiscountRequestController.createDiscountRequest';
import approveRequest         from '@salesforce/apex/DiscountRequestController.approveRequest';
import rejectRequest          from '@salesforce/apex/DiscountRequestController.rejectRequest';

// SLDS badge styles mapped to each Status picklist value
const BADGE_CLASS = {
    'Approved':      'slds-badge slds-theme_success',
    'Auto-Approved': 'slds-badge slds-theme_success',
    'Pending':       'slds-badge slds-theme_warning',
    'Rejected':      'slds-badge slds-theme_error'
};

export default class DiscountRequestPanel extends LightningElement {

    @api recordId;

    // ── State ────────────────────────────────────────────────────────────────
    isLoading          = false;
    showForm           = false;
    newDiscount        = null;
    newReason          = '';
    rejectingRequestId = null;
    rejectComment      = '';
    hasApproverPermission  = false;
    hasRequesterPermission = false;
    wireError              = null;

    // Stored so refreshApex can target the exact wire result
    _wiredRequestsResult;

    // ── Wire: list of Discount Requests ─────────────────────────────────────
    @wire(getDiscountRequests, { opportunityId: '$recordId' })
    wiredRequests(result) {
        this._wiredRequestsResult = result;
        if (result.error) {
            const raw = result.error?.body?.message ?? result.error?.message ?? '';
            this.wireError = raw.includes('DiscountRequestController')
                ? 'You don\'t have permission to view discount requests. Contact your administrator.'
                : raw || 'Failed to load discount requests.';
        } else {
            this.wireError = null;
        }
    }

    // ── Wire: opportunity closed check ───────────────────────────────────────
    @wire(getRecord, { recordId: '$recordId', fields: [OPP_IS_CLOSED] })
    wiredOpportunity;

    // ── Wire: permission checks ──────────────────────────────────────────────
    @wire(hasApproverPermission)
    wiredApproverPermission({ data }) {
        if (data !== undefined) this.hasApproverPermission = data;
    }

    @wire(hasRequesterPermission)
    wiredRequesterPermission({ data }) {
        if (data !== undefined) this.hasRequesterPermission = data;
    }

    // ── Derived getters ──────────────────────────────────────────────────────

    get enrichedRequests() {
        const records = this._wiredRequestsResult?.data;
        if (!records) return [];
        return records.map(req => ({
            Id:                       req.Id,
            Name:                     req.Name,
            Requested_Discount__c:    req.Requested_Discount__c,
            Status__c:                req.Status__c,
            Required_Approver_Level__c: req.Required_Approver_Level__c,
            Final_Discount__c:        req.Final_Discount__c,
            Decision_Timestamp__c:    req.Decision_Timestamp__c,
            Approver_Comments__c:     req.Approver_Comments__c,
            Reason__c:                req.Reason__c ?? '',
            reasonDisplay:            req.Reason__c || '—',
            approverName:             req.Approver__r?.Name ?? '—',
            badgeClass:               BADGE_CLASS[req.Status__c] ?? 'slds-badge',
            isPending:                req.Status__c === 'Pending',
            isRejecting:              req.Id === this.rejectingRequestId
        }));
    }

    get isEmpty() {
        const records = this._wiredRequestsResult?.data;
        return !records || records.length === 0;
    }

    get hasRequests() {
        return !this.isEmpty;
    }

    get isOpportunityClosed() {
        return getFieldValue(this.wiredOpportunity?.data, OPP_IS_CLOSED) === true;
    }

    get canSubmitRequest() {
        return this.hasRequesterPermission && !this.isOpportunityClosed;
    }

    get showEmptyState() {
        return this.isEmpty && !this.isOpportunityClosed;
    }

    get hasPendingRequest() {
        const records = this._wiredRequestsResult?.data;
        return records?.some(req => req.Status__c === 'Pending') ?? false;
    }

    // ── New request form ─────────────────────────────────────────────────────

    handleNewRequest() {
        this.showForm = true;
    }

    handleCancel() {
        this.showForm    = false;
        this.newDiscount = null;
        this.newReason   = '';
    }

    handleDiscountChange(event) {
        this.newDiscount = event.target.value;
    }

    handleReasonChange(event) {
        this.newReason = event.target.value;
    }

    async handleSubmit() {
        if (!this.newDiscount && this.newDiscount !== 0) {
            this.showToast('Error', 'Please enter a discount percentage.', 'error');
            return;
        }
        this.isLoading = true;
        try {
            await createDiscountRequest({
                opportunityId: this.recordId,
                discount:      parseFloat(this.newDiscount),
                reason:        this.newReason
            });
            this.showToast('Success', 'Discount request submitted successfully.', 'success');
            this.handleCancel();
            await refreshApex(this._wiredRequestsResult);
        } catch (error) {
            this.showToast('Error', this.extractMessage(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Approve ──────────────────────────────────────────────────────────────

    async handleApprove(event) {
        const requestId = event.currentTarget.dataset.id;
        this.isLoading  = true;
        try {
            await approveRequest({ requestId });
            this.showToast('Success', 'Discount request approved.', 'success');
            await refreshApex(this._wiredRequestsResult);
        } catch (error) {
            this.showToast('Error', this.extractMessage(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Reject ───────────────────────────────────────────────────────────────

    handleRejectOpen(event) {
        this.rejectingRequestId = event.currentTarget.dataset.id;
        this.rejectComment      = '';
    }

    handleRejectCancel() {
        this.rejectingRequestId = null;
        this.rejectComment      = '';
    }

    handleRejectCommentChange(event) {
        this.rejectComment = event.target.value;
    }

    async handleRejectSubmit(event) {
        const requestId = event.currentTarget.dataset.id;
        if (!this.rejectComment?.trim()) {
            this.showToast('Error', 'Rejection comments are required.', 'error');
            return;
        }
        this.isLoading = true;
        try {
            await rejectRequest({ requestId, comments: this.rejectComment });
            this.showToast('Success', 'Discount request rejected.', 'success');
            this.rejectingRequestId = null;
            this.rejectComment      = '';
            await refreshApex(this._wiredRequestsResult);
        } catch (error) {
            this.showToast('Error', this.extractMessage(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractMessage(error) {
        return error?.body?.message ?? error?.message ?? 'An unexpected error occurred.';
    }
}
