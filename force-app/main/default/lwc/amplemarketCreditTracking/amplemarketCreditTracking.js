import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDashboard from '@salesforce/apex/AmplemarketCreditController.getDashboard';
import getEligibleUsers from '@salesforce/apex/AmplemarketCreditController.getEligibleUsers';
import saveConfig from '@salesforce/apex/AmplemarketCreditController.saveConfig';
import sendDigestNow from '@salesforce/apex/AmplemarketCreditController.sendDigestNow';


const DAY_OPTIONS = [
    { label: 'Monday', value: 'MON' },
    { label: 'Tuesday', value: 'TUE' },
    { label: 'Wednesday', value: 'WED' },
    { label: 'Thursday', value: 'THU' },
    { label: 'Friday', value: 'FRI' },
    { label: 'Saturday', value: 'SAT' },
    { label: 'Sunday', value: 'SUN' }
];

export default class AmplemarketCreditTracking extends LightningElement {
    @track rows = [];
    @track userOptions = [];
    limits = {};
    enforceLimits = false;
    notifyUserId = null;
    weekStart;
    isLoading = true;
    isSaving = false;

    isSendingTest = false;






    @track digest = {
        enabled: false,
        recipients: '',
        dayOfWeek: 'MON',
        hour: 8,
        minute: 0,
        nextRun: null,
        timeZone: ''
    };

    get dayOptions() {
        return DAY_OPTIONS;
    }

    get digestScheduleText() {
        if (!this.digest.enabled) return 'Digest is off.';
        if (this.digest.nextRun) {
            return `Next digest: ${this.digest.nextRun} (${this.digest.timeZone})`;
        }
        return 'Save to schedule the digest.';
    }

    @track annual = {
        allowance: null,
        used: 0,
        start: null,
        end: null,
        configured: false,
        pct: 0,
        over: false,
        barClass: 'bar bar-ok',
        barStyle: 'width:0%',
        text: ''
    };

    connectedCallback() {
        this.load();
        getEligibleUsers()
            .then((opts) => {
                this.userOptions = opts;
            })
            .catch(() => {
                this.userOptions = [];
            });
    }

    async load() {
        this.isLoading = true;
        try {
            const d = await getDashboard();
            this.enforceLimits = d.enforceLimits;
            this.notifyUserId = d.notifyUserId;
            this.weekStart = d.weekStart;
            this.buildAnnual(d);
            this.digest = {
                enabled: d.digestEnabled,
                recipients: d.digestRecipients || '',
                dayOfWeek: d.digestDayOfWeek || 'MON',
                hour: d.digestHour === null || d.digestHour === undefined ? 8 : d.digestHour,
                minute: d.digestMinute === null || d.digestMinute === undefined ? 0 : d.digestMinute,
                nextRun: d.digestNextRun,
                timeZone: d.digestTimeZone
            };
            this.limits = {};
            this.rows = d.categories.map((c) => {
                this.limits[c.key] = c.weeklyLimit;
                const hasLimit = c.weeklyLimit !== null && c.weeklyLimit !== undefined && c.weeklyLimit > 0;
                const pct = hasLimit ? Math.min(100, Math.round((c.weeklyUsed / c.weeklyLimit) * 100)) : 0;
                const over = hasLimit && c.weeklyUsed >= c.weeklyLimit;
                return {
                    key: c.key,
                    label: c.label,
                    weeklyUsed: c.weeklyUsed,
                    weeklyLimit: c.weeklyLimit,
                    allTimeUsed: c.allTimeUsed,
                    hasLimit,
                    pct,
                    over,
                    limitText: hasLimit ? `${c.weeklyUsed} / ${c.weeklyLimit}` : `${c.weeklyUsed} (no limit)`,
                    barStyle: `width:${pct}%`,
                    barClass: over
                        ? 'bar bar-over'
                        : pct >= 80
                        ? 'bar bar-warn'
                        : 'bar bar-ok'
                };
            });
        } catch (e) {
            this.toast('Error', this.errText(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    buildAnnual(d) {
        const allowance = d.annualAllowance;
        const used = d.annualUsed || 0;
        const hasAllowance = allowance !== null && allowance !== undefined && allowance > 0;
        const pct = hasAllowance ? Math.min(100, Math.round((used / allowance) * 100)) : 0;
        const over = hasAllowance && used >= allowance;
        this.annual = {
            allowance,
            used,
            start: d.contractStart,
            end: d.contractEnd,
            configured: d.contractConfigured,
            pct,
            over,
            barClass: over ? 'bar bar-over' : pct >= 80 ? 'bar bar-warn' : 'bar bar-ok',
            barStyle: `width:${pct}%`,
            text: hasAllowance ? `${used} / ${allowance}` : `${used} (no allowance set)`
        };
    }

    get remainingText() {
        if (!this.annual.allowance || this.annual.allowance <= 0) return '';
        const left = this.annual.allowance - this.annual.used;
        return `${left > 0 ? left : 0} credits remaining`;
    }

    handleAnnualAllowanceChange(event) {
        const v = event.target.value;
        this.annual = { ...this.annual, allowance: v === '' || v === null ? null : Number(v) };
    }

    handleContractStartChange(event) {
        this.annual = { ...this.annual, start: event.target.value };
    }

    handleContractEndChange(event) {
        this.annual = { ...this.annual, end: event.target.value };
    }




    handleDigestEnabledChange(event) {
        this.digest = { ...this.digest, enabled: event.target.checked };
    }

    handleDigestRecipientsChange(event) {
        this.digest = { ...this.digest, recipients: event.target.value };
    }

    handleDigestDayChange(event) {
        this.digest = { ...this.digest, dayOfWeek: event.detail.value };
    }

    handleDigestHourChange(event) {
        this.digest = { ...this.digest, hour: Number(event.target.value) };
    }

    handleDigestMinuteChange(event) {
        this.digest = { ...this.digest, minute: Number(event.target.value) };
    }

    async handleSendTest() {
        this.isSendingTest = true;
        try {
            const msg = await sendDigestNow();
            this.toast('Digest', msg, 'success');
        } catch (e) {
            this.toast('Error', this.errText(e), 'error');
        } finally {
            this.isSendingTest = false;
        }
    }

    handleLimitChange(event) {
        const key = event.target.dataset.key;
        const v = event.target.value;
        this.limits[key] = v === '' || v === null ? null : Number(v);
    }

    handleEnforceChange(event) {
        this.enforceLimits = event.target.checked;
    }

    handleNotifyChange(event) {
        this.notifyUserId = event.detail.value;
    }

    limitValue(key) {
        return this.limits[key];
    }

    get personLimit() {
        return this.limits.personSearch;
    }
    get companyLimit() {
        return this.limits.companySearch;
    }
    get emailLimit() {
        return this.limits.emailReveal;
    }
    get phoneLimit() {
        return this.limits.phoneReveal;
    }

    async handleSave() {
        this.isSaving = true;
        try {
            await saveConfig({
                personLimit: this.limits.personSearch ?? null,
                companyLimit: this.limits.companySearch ?? null,
                emailLimit: this.limits.emailReveal ?? null,
                phoneLimit: this.limits.phoneReveal ?? null,
                enforceLimits: this.enforceLimits,
                notifyUserId: this.notifyUserId || '',
                annualAllowance: this.annual.allowance ?? null,
                contractStart: this.annual.start || '',
                contractEnd: this.annual.end || '',
                digestEnabled: this.digest.enabled,
                digestRecipients: this.digest.recipients || '',
                digestDayOfWeek: this.digest.dayOfWeek || 'MON',
                digestHour: this.digest.hour ?? 8,
                digestMinute: this.digest.minute ?? 0
            });
            this.toast('Saved', 'Credit settings updated.', 'success');
            await this.load();
        } catch (e) {
            this.toast('Error', this.errText(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    errText(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Unexpected error';
    }
}
