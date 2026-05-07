import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import canManage from '@salesforce/customPermission/Manage_Amplemarket_Settings';
import getCatalog from '@salesforce/apex/AmplemarketSettingsController.getCatalog';
import getMappings from '@salesforce/apex/AmplemarketSettingsController.getMappings';
import saveMappings from '@salesforce/apex/AmplemarketSettingsController.saveMappings';

const OBJECTS = ['Lead', 'Contact', 'Account'];
const UPDATE_BEHAVIOR_OPTIONS = [
    { label: 'Always', value: 'Always' },
    { label: 'Only if Empty', value: 'Only if Empty' }
];

export default class AmplemarketSettings extends LightningElement {
    @track activeObject = 'Lead';
    @track catalogs = {};
    @track mappingsByObject = {
        Lead: { matchInputs: [], outputs: [], reveals: { email: false, phone: false } },
        Contact: { matchInputs: [], outputs: [], reveals: { email: false, phone: false } },
        Account: { matchInputs: [], outputs: [], reveals: { email: false, phone: false } }
    };
    isLoading = true;
    isSaving = false;

    get canManage() {
        return canManage;
    }

    get tabs() {
        return OBJECTS.map((o) => ({
            label: o,
            value: o,
            variant: o === this.activeObject ? 'brand' : 'neutral'
        }));
    }

    get currentCatalog() {
        return this.catalogs[this.activeObject];
    }

    get currentMappings() {
        return this.mappingsByObject[this.activeObject];
    }

    get isPersonObject() {
        return this.activeObject === 'Lead' || this.activeObject === 'Contact';
    }

    get updateBehaviorOptions() {
        return UPDATE_BEHAVIOR_OPTIONS;
    }

    @wire(getCatalog)
    wiredCatalog({ data, error }) {
        if (data) {
            const map = {};
            data.forEach((c) => {
                map[c.objectApiName] = c;
            });
            this.catalogs = map;
            this.loadExistingMappings();
        } else if (error) {
            this.toast('Error', this.extractError(error), 'error');
            this.isLoading = false;
        }
    }

    async loadExistingMappings() {
        try {
            const rows = await getMappings();
            const grouped = {
                Lead: { matchInputs: [], outputs: [], reveals: { email: false, phone: false } },
                Contact: { matchInputs: [], outputs: [], reveals: { email: false, phone: false } },
                Account: { matchInputs: [], outputs: [], reveals: { email: false, phone: false } }
            };
            rows.forEach((r) => {
                const bucket = grouped[r.objectApiName];
                if (!bucket) return;
                if (r.mappingType === 'Match Input') {
                    bucket.matchInputs.push({ ...r });
                    if (r.amplemarketField === 'email' && r.revealEmail) bucket.reveals.email = true;
                    if (r.revealPhone) bucket.reveals.phone = true;
                } else if (r.mappingType === 'Output Field') {
                    bucket.outputs.push({
                        ...r,
                        updateBehavior: r.updateBehavior || 'Always',
                        key: r.id || `new_${Math.random()}`
                    });
                }
            });
            // Ensure every match-input key has a row (so the UI shows all keys)
            OBJECTS.forEach((obj) => {
                const cat = this.catalogs[obj];
                if (!cat) return;
                cat.matchInputKeys.forEach((k) => {
                    const exists = grouped[obj].matchInputs.find((mi) => mi.amplemarketField === k.value);
                    if (!exists) {
                        grouped[obj].matchInputs.push({
                            objectApiName: obj,
                            mappingType: 'Match Input',
                            amplemarketField: k.value,
                            salesforceField: '',
                            revealEmail: false,
                            revealPhone: false,
                            isActive: true
                        });
                    }
                });
            });
            this.mappingsByObject = grouped;
        } catch (e) {
            this.toast('Error', this.extractError(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleTabClick(event) {
        this.activeObject = event.target.dataset.obj;
    }

    handleMatchFieldChange(event) {
        const key = event.target.dataset.key;
        const value = event.detail.value;
        const bucket = this.mappingsByObject[this.activeObject];
        const row = bucket.matchInputs.find((mi) => mi.amplemarketField === key);
        if (row) {
            row.salesforceField = value;
            this.mappingsByObject = { ...this.mappingsByObject };
        }
    }

    handleRevealEmailChange(event) {
        this.mappingsByObject[this.activeObject].reveals.email = event.target.checked;
        this.mappingsByObject = { ...this.mappingsByObject };
    }

    handleRevealPhoneChange(event) {
        this.mappingsByObject[this.activeObject].reveals.phone = event.target.checked;
        this.mappingsByObject = { ...this.mappingsByObject };
    }

    handleAddOutput() {
        this.mappingsByObject[this.activeObject].outputs.unshift({
            key: `new_${Date.now()}`,
            objectApiName: this.activeObject,
            mappingType: 'Output Field',
            amplemarketField: '',
            salesforceField: '',
            updateBehavior: 'Always',
            isActive: true
        });
        this.mappingsByObject = { ...this.mappingsByObject };
    }

    handleOutputBehaviorChange(event) {
        const key = event.target.dataset.key;
        const row = this.mappingsByObject[this.activeObject].outputs.find((o) => o.key === key);
        if (row) {
            row.updateBehavior = event.detail.value;
            this.mappingsByObject = { ...this.mappingsByObject };
        }
    }

    handleOutputAmField(event) {
        const key = event.target.dataset.key;
        const row = this.mappingsByObject[this.activeObject].outputs.find((o) => o.key === key);
        if (row) {
            row.amplemarketField = event.detail.value;
            this.mappingsByObject = { ...this.mappingsByObject };
        }
    }

    handleOutputSfField(event) {
        const key = event.target.dataset.key;
        const row = this.mappingsByObject[this.activeObject].outputs.find((o) => o.key === key);
        if (row) {
            row.salesforceField = event.detail.value;
            this.mappingsByObject = { ...this.mappingsByObject };
        }
    }

    handleOutputActiveChange(event) {
        const key = event.target.dataset.key;
        const row = this.mappingsByObject[this.activeObject].outputs.find((o) => o.key === key);
        if (row) {
            row.isActive = event.target.checked;
            this.mappingsByObject = { ...this.mappingsByObject };
        }
    }

    handleRemoveOutput(event) {
        const key = event.target.dataset.key;
        const bucket = this.mappingsByObject[this.activeObject];
        bucket.outputs = bucket.outputs.filter((o) => o.key !== key);
        this.mappingsByObject = { ...this.mappingsByObject };
    }

    async handleSave() {
        if (!this.canManage) {
            this.toast('Forbidden', 'You do not have the Manage Amplemarket Settings permission.', 'error');
            return;
        }
        const flat = [];
        OBJECTS.forEach((obj) => {
            const bucket = this.mappingsByObject[obj];
            bucket.matchInputs.forEach((mi) => {
                if (!mi.amplemarketField || !mi.salesforceField) return;
                flat.push({
                    id: mi.id,
                    objectApiName: obj,
                    mappingType: 'Match Input',
                    amplemarketField: mi.amplemarketField,
                    salesforceField: mi.salesforceField,
                    revealEmail: mi.amplemarketField === 'email' && bucket.reveals.email,
                    revealPhone: bucket.reveals.phone,
                    isActive: mi.isActive !== false
                });
            });
            bucket.outputs.forEach((o) => {
                if (!o.amplemarketField || !o.salesforceField) return;
                flat.push({
                    id: o.id,
                    objectApiName: obj,
                    mappingType: 'Output Field',
                    amplemarketField: o.amplemarketField,
                    salesforceField: o.salesforceField,
                    revealEmail: false,
                    revealPhone: false,
                    updateBehavior: o.updateBehavior || 'Always',
                    isActive: o.isActive !== false
                });
            });
        });

        this.isSaving = true;
        try {
            // eslint-disable-next-line no-console
            console.log('Amplemarket save payload:', JSON.stringify(flat, null, 2));
            const result = await saveMappings({ mappingsJson: JSON.stringify(flat) });
            // eslint-disable-next-line no-console
            console.log('saveMappings raw result:', JSON.stringify(result));
            const saved = typeof result?.saved === 'number' ? result.saved : 0;
            const reasons = Array.isArray(result?.skippedReasons) ? result.skippedReasons : [];
            if (reasons.length > 0) {
                // eslint-disable-next-line no-console
                console.warn('Amplemarket skipped rows:', reasons);
            }
            const msg = reasons.length > 0
                ? `${saved} saved; ${reasons.length} skipped. First reason: ${reasons[0]}`
                : `${saved} mapping(s) saved.`;
            this.toast('Saved', msg, reasons.length > 0 ? 'warning' : 'success');
            await this.loadExistingMappings();
        } catch (e) {
            this.toast('Save failed', this.extractError(e), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractError(err) {
        if (!err) return 'Unknown error';
        if (typeof err === 'string') return err;
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}
