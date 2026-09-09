(function (root, factory) {
  if (typeof window === 'undefined' && typeof module === 'object' && module.exports) module.exports = factory();
  else root.StampBotSubmissions = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  return class StampBotSubmissions {
    constructor(options) {
      this.endpoint = new URL(options.endpoint, options.baseUrl || location.href);
      this.fetch = options.fetch || globalThis.fetch.bind(globalThis);
      this.onState = options.onState || function () {};
      this.sleep = options.sleep || (ms => new Promise(resolve => setTimeout(resolve, ms)));
      this.now = options.now || Date.now;
      this.maxWaitMs = options.maxWaitMs || 15 * 60 * 1000;
      this.requestTimeoutMs = options.requestTimeoutMs || 15000;
      this.generation = 0;
    }

    stop() { this.generation += 1; }

    async request(url, options) {
      const abort = new AbortController();
      const timeout = setTimeout(() => abort.abort(), this.requestTimeoutMs);
      try {
        const response = await this.fetch(url, Object.assign({ cache: 'no-store', signal: abort.signal }, options));
        const data = await response.json().catch(() => ({}));
        if (!response.ok) {
          const error = new Error(data.message || 'StampBot could not complete this request.');
          error.transient = response.status === 429 || response.status >= 500;
          throw error;
        }
        return data;
      } finally {
        clearTimeout(timeout);
      }
    }

    descriptor(data) {
      const id = String(data.submission_id || data.timestamp_id || '');
      if (!/^\d+$/.test(id)) throw new Error('StampBot did not return a submission ID.');
      const statusUrl = new URL(data.status_url || '/api/submissions/' + id, this.endpoint);
      if (statusUrl.origin !== this.endpoint.origin || statusUrl.pathname !== '/api/submissions/' + id) {
        throw new Error('StampBot returned an invalid status URL.');
      }
      return { timestamp_id: id, status_url: statusUrl.href };
    }

    emit(data, generation) {
      if (generation === this.generation) this.onState(data);
    }

    async submit(attrs) {
      const generation = ++this.generation;
      this.emit({ status: 'submitting' }, generation);
      try {
        const data = await this.request(this.endpoint.href, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(attrs)
        });
        if (generation !== this.generation) return;
        if (data.status === 'processing') {
          await this.poll(this.descriptor(data), generation, data);
        } else if (data.status === 'success' || data.status === 'error') {
          this.emit(data, generation);
        } else {
          throw new Error('StampBot returned an unexpected submission status.');
        }
      } catch (error) {
        this.emit({ status: 'error', message: error.message || 'Could not confirm this submission. Please check the feed or try again.' }, generation);
      }
    }

    async watch(saved) {
      const generation = ++this.generation;
      try {
        await this.poll(this.descriptor(saved), generation, { status: 'processing' });
      } catch (error) {
        this.emit({ status: 'error', message: error.message }, generation);
      }
    }

    async poll(descriptor, generation, initial) {
      const started = this.now();
      let attempt = 0;
      let failures = 0;
      this.emit(Object.assign({}, initial, descriptor, { status: 'processing' }), generation);
      while (generation === this.generation && this.now() - started < this.maxWaitMs) {
        if (attempt > 0) await this.sleep(Math.min(2000 * Math.pow(1.5, attempt - 1), 10000));
        if (generation !== this.generation) return;
        if (this.now() - started >= this.maxWaitMs) break;
        attempt += 1;
        try {
          const data = await this.request(descriptor.status_url);
          if (generation !== this.generation) return;
          if (!['processing', 'success', 'error'].includes(data.status)) {
            const error = new Error('StampBot returned an unexpected submission status.');
            error.transient = true;
            throw error;
          }
          failures = 0;
          this.emit(Object.assign({}, data, descriptor), generation);
          if (data.status !== 'processing') return;
        } catch (error) {
          if (generation !== this.generation) return;
          failures += 1;
          if (error.transient === false) {
            this.emit(Object.assign({}, descriptor, { status: 'error', message: error.message }), generation);
            return;
          }
          if (failures >= 5) break;
        }
      }
      this.emit(Object.assign({}, descriptor, {
        status: 'paused',
        message: 'Your submission is saved. Live updates are paused; reopen this popup or check the feed for its result.'
      }), generation);
    }
  };
});
