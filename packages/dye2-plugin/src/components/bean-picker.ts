export const beanPickerComponent = `
class Dye2BeanPicker extends HTMLElement {
  constructor() {
    super();
    this._beans = [];
    this._expandedBeanId = null;
    this._batches = [];
    this._selectedBatchId = null;
    this._loading = true;
    this._loadingBatches = false;
  }

  connectedCallback() {
    this.render();
    this.fetchBeans();
  }

  async fetchBeans() {
    this._loading = true;
    this.render();
    try {
      const res = await fetch('/api/v1/beans');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._beans = await res.json();
      this._loading = false;
      this.render();
    } catch (err) {
      this._loading = false;
      this.innerHTML = '<p style="color: #ff6b6b;">Failed to load beans: ' + err.message + '</p>';
    }
  }

  async expandBean(beanId) {
    if (this._expandedBeanId === beanId) {
      this._expandedBeanId = null;
      this._batches = [];
      this.render();
      return;
    }
    this._expandedBeanId = beanId;
    this._batches = [];
    this._loadingBatches = true;
    this.render();
    try {
      const res = await fetch('/api/v1/beans/' + beanId + '/batches');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._batches = await res.json();
      this._loadingBatches = false;
      this.render();
    } catch (err) {
      this._loadingBatches = false;
      this.innerHTML = '<p style="color: #ff6b6b;">Failed to load batches: ' + err.message + '</p>';
    }
  }

  async selectBatch(batchId, bean) {
    this._selectedBatchId = batchId;
    this.render();

    const detail = {
      beanBatchId: batchId,
      coffeeName: bean.name || '',
      coffeeRoaster: bean.roaster || '',
    };

    // Update workflow
    try {
      await fetch('/api/v1/workflow', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ context: detail }),
      });
    } catch (err) {
      console.error('[dye2-bean-picker] Workflow update failed:', err);
    }

    // Dispatch DOM event
    this.dispatchEvent(new CustomEvent('picker-done', { detail, bubbles: true }));

    // PostMessage for iframe integration
    window.parent.postMessage({ type: 'dye2-picker-done', ...detail }, '*');
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  _formatDate(iso) {
    if (!iso) return '';
    try {
      const d = new Date(iso);
      return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    } catch (e) {
      return iso;
    }
  }

  render() {
    if (this._loading) {
      this.innerHTML = '<h1>Select Bean</h1><div class="card"><p class="text-muted">Loading beans...</p></div>';
      return;
    }

    const beans = this._beans;
    this.innerHTML = \`
      <h1>Select Bean</h1>
      \${beans.length === 0
        ? '<p class="text-muted">No beans available. Add beans in the Beans management page.</p>'
        : beans.map(bean => {
            const isExpanded = this._expandedBeanId === bean.id;
            return \`
              <div class="card picker-bean" data-bean-id="\${bean.id}" style="cursor:pointer;">
                <div class="flex-between">
                  <div>
                    <span style="margin-right:6px;">\${isExpanded ? '&#9660;' : '&#9654;'}</span>
                    <strong>\${this._esc(bean.name) || 'Unnamed'}</strong>
                    <span class="text-muted"> by \${this._esc(bean.roaster) || 'Unknown roaster'}</span>
                  </div>
                  <div class="flex">
                    \${bean.country ? '<span class="tag">' + this._esc(bean.country) + '</span>' : ''}
                    \${bean.processing ? '<span class="tag">' + this._esc(bean.processing) + '</span>' : ''}
                  </div>
                </div>
              </div>
              \${isExpanded ? this._renderBatches(bean) : ''}
            \`;
          }).join('')
      }
    \`;

    // Event listeners for bean expand/collapse
    this.querySelectorAll('.picker-bean[data-bean-id]').forEach(card => {
      card.addEventListener('click', () => {
        const id = card.getAttribute('data-bean-id');
        this.expandBean(id);
      });
    });

    // Event listeners for batch selection
    this.querySelectorAll('.picker-batch[data-batch-id]').forEach(card => {
      card.addEventListener('click', (e) => {
        e.stopPropagation();
        const batchId = card.getAttribute('data-batch-id');
        const beanId = card.getAttribute('data-bean-id');
        const bean = this._beans.find(b => b.id === beanId) || {};
        this.selectBatch(batchId, bean);
      });
    });
  }

  _renderBatches(bean) {
    if (this._loadingBatches) {
      return '<div style="margin-left:24px;margin-bottom:12px;" class="card"><p class="text-muted">Loading batches...</p></div>';
    }

    const batches = this._batches;
    if (batches.length === 0) {
      return '<div style="margin-left:24px;margin-bottom:12px;"><p class="text-muted text-small">No batches for this bean.</p></div>';
    }

    return batches.map(b => {
      const isSelected = this._selectedBatchId === b.id;
      const selectedStyle = isSelected
        ? 'border-color: #2ecc71; background: #1a3a2a;'
        : '';
      return \`
        <div class="card picker-batch" data-batch-id="\${b.id}" data-bean-id="\${bean.id}"
             style="margin-left:24px;margin-bottom:8px;cursor:pointer;\${selectedStyle}">
          <div class="flex-between">
            <div class="flex">
              \${isSelected ? '<span style="color:#2ecc71;margin-right:6px;">&#10003;</span>' : ''}
              \${b.roastDate ? '<strong>Roasted: ' + this._formatDate(b.roastDate) + '</strong>' : '<strong>Batch</strong>'}
            </div>
            <div class="flex">
              \${b.roastLevel ? '<span class="tag">' + this._esc(b.roastLevel) + '</span>' : ''}
              \${b.frozen ? '<span class="tag">frozen</span>' : ''}
            </div>
          </div>
          <div class="flex text-small text-muted mt-8" style="flex-wrap:wrap;">
            \${b.weight != null ? '<span>' + (b.weightRemaining != null ? b.weightRemaining + 'g / ' : '') + b.weight + 'g</span>' : ''}
            \${b.price != null ? '<span>' + (b.currency || '') + ' ' + b.price.toFixed(2) + '</span>' : ''}
          </div>
        </div>
      \`;
    }).join('');
  }
}
customElements.define('dye2-bean-picker', Dye2BeanPicker);
`;
