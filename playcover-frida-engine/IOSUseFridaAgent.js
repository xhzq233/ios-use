(function(){
const format = (value) => {
  if (value === undefined) return 'undefined';
  if (value === null) return 'null';
  try { const json = JSON.stringify(value, null, 2); if (json !== undefined) return json; } catch (_) {}
  try { return String(value); } catch (_) { return '<unprintable>'; }
};
if (globalThis.console) { for (const level of ['log','info','warn','error','debug']) { console[level] = (...args) => send({ iosUse: 'event', kind: 'console', level, display: args.map(format).join(' ') }); } }
const handle = (message) => {
  const p = message && message.payload ? message.payload : {};
  const id = String(p.id || '');
  try {
    const result = (0, eval)(String(p.script || ''));
    Promise.resolve(result).then(value => send({ iosUse: 'result', id, display: format(value) }), error => {
      const message = String(error && error.message || error);
      const stack = String(error && error.stack || '');
      send({ iosUse: 'event', kind: 'error', display: stack ? `${message}\n${stack}` : message });
      send({ iosUse: 'error', id, message, stack });
    });
  } catch (error) {
    const message = String(error && error.message || error);
    const stack = String(error && error.stack || '');
    send({ iosUse: 'event', kind: 'error', display: stack ? `${message}\n${stack}` : message });
    send({ iosUse: 'error', id, message, stack });
  }
  recv('ios_use_eval', handle);
};
recv('ios_use_eval', handle);
})();
