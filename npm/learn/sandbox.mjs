// An opaque frame owns a dedicated execution worker. CSP applies to its blob
// worker too: learner code has no network, DOM, storage or parent-origin access.
/** Execute a compiled bundle in an opaque frame worker, keeping cancellation and timeout control on the responsive parent. ref:DEC-learn-course-preview */
export function execute(code, {signal, timeout = 15000} = {})
{
  return new Promise((resolve, reject) =>
  {
    const frame = document.createElement('iframe');
    frame.hidden = true;
    frame.title = 'Isolated lesson execution';
    frame.setAttribute('sandbox', 'allow-scripts');
    let timer;
    const finish = (error, value) =>
    {
      clearTimeout(timer);
      window.removeEventListener('message', listen);
      signal?.removeEventListener('abort', abort);
      frame.remove();
      error ? reject(error) : resolve(value);
    };
    const abort = () =>
      finish(new DOMException('Execution cancelled', 'AbortError'));
    const listen = event =>
    {
      if (event.source !== frame.contentWindow)
      {
        return;
      }
      if (event.data?.ready)
      {
        frame.contentWindow.postMessage({code}, '*');
      }
      else if (event.data?.result)
      {
        finish(null, event.data.result);
      }
      else if (event.data?.error)
      {
        finish(new Error(event.data.error));
      }
    };
    if (signal?.aborted)
    {
      abort();
      return;
    }
    window.addEventListener('message', listen);
    signal?.addEventListener('abort', abort, {once: true});
    timer = setTimeout(
      () => finish(new Error('Execution timed out; your draft is saved.')),
      timeout,
    );
    frame.src = new URL('./sandbox-frame.html', import.meta.url).href;
    document.body.append(frame);
  });
}
/** Own the execution worker inside the network-disabled frame and relay its result before terminating it. ref:DEC-learn-course-preview */
export function frameMain()
{
  addEventListener(
    'message',
    ({source, data}) =>
    {
      if (source !== parent || typeof data.code !== 'string')
      {
        return;
      }
      const url = URL.createObjectURL(
        new Blob([data.code], {type: 'text/javascript'}),
      );
      const worker = new Worker(url);
      worker.onmessage = event =>
      {
        parent.postMessage(event.data, '*');
        worker.terminate();
        URL.revokeObjectURL(url);
      };
      worker.onerror = event =>
      {
        parent.postMessage(
          {error: event.message || 'Learner execution failed'},
          '*',
        );
        worker.terminate();
        URL.revokeObjectURL(url);
      };
    },
    {once: true},
  );
  parent.postMessage({ready: true}, '*');
}
