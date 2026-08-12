import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAutomation from '@salesforce/apex/AmplemarketCreditController.getAutomation';
import saveAutomation from '@salesforce/apex/AmplemarketCreditController.saveAutomation';
import runAutomationNow from '@salesforce/apex/AmplemarketCreditController.runAutomationNow';

const INTERVAL_OPTIONS = [
    { label: 'Every 5 minutes', value: '5' },
    { label: 'Every 10 minutes', value: '10' },
    { label: 'Every 15 minutes', value: '15' },
    { label: 'Every 20 minutes', value: '20' },
    { label: 'Every 30 minutes', value: '30' },
    { label: 'Every hour', value: '60' }
];

export default class AmplemarketAutoEnrichment extends LightningElement {
    @track auto = {
        enabled: false,
        interval: '15',
        runAsName: null,
        runAsIsCurrentUser: false,
        nextRun: null,
        pending: 0,
        failed: 0,
        currentUserName: ''
    };

    isLoading = true;
    isSaving = false;
    isRunningNow = false;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        try {
            const a = await getAutomation();
            this.auto = {
                enabled: a.enabled,
                interval: String(a.interval === null || a.interval === undefined ? 15 : a.interval),
                runAsName: a.runAsName,
                runAsIsCurrentUser: a.runAsIsCurrentUser,
                nextRun: a.nextRun,
                pending: a.pending,
                failed: a.failed,
                currentUserName: a.currentUserName
            };
        } catch (e) {
            this.toast('Error', this.errText(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    get intervalOptions() {
        return INTERVAL_OPTIONS;
    }

    get statusVariant() {
        return this.auto.enabled ? 'success' : 'inverse';
    }

    get statusLabel() {
        return this.auto.enabled ? 'On' : 'Off';
    }

    get runAsText() {
        if (!this.auto.runAsName) {
            return `Saving will run enrichment as you (${this.auto.currentUserName}).`;
        }
        return `Enrichment runs as ${this.auto.runAsName}.`;
    }

    get nextRunText() {
        if (!this.auto.enabled) return 'No job is scheduled.';
        return this.auto.nextRun ? `Next check: ${this.auto.nextRun}.` : 'Save to schedule the job.';
    }

    get queueText() {
        const p = this.auto.pending || 0;
        const f = this.auto.failed || 0;
        const base = `${p} request${p === 1 ? '' : 's'} waiting`;
        return f > 0 ? `${base}, ${f} failed` : base;
    }

    get showTakeOverWarning() {
        return this.auto.runAsName && !this.auto.runAsIsCurrentUser;
    }

    get hasFailures() {
        return (this.auto.failed || 0) > 0;
    }

    handleEnabledChange(event) {
        this.auto = { ...this.auto, enabled: event.target.checked };
    }

    handleIntervalChange(event) {
        this.auto = { ...this.auto, interval: event.detail.value };
    }

    async handleSave() {
        this.isSaving = true;
        try {
            await saveAutomation({
                enabled: this.auto.enabled,
                interval: Number(this.auto.interval || 15)
            });
            this.toast('Saved', 'Automated enrichment settings updated.', 'success');
            await this.load();
        } catch (e) {
            this.toast('Error', this.errText(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleRunNow() {
        this.isRunningNow = true;
        try {
            const msg = await runAutomationNow();
            this.toast('Automated enrichment', msg, 'success');
            await this.load();
        } catch (e) {
            this.toast('Error', this.errText(e), 'error');
        } finally {
            this.isRunningNow = false;
        }
    }

    handleRefresh() {
        this.load();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    errText(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}
