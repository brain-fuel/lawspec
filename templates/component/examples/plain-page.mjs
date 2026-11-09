// ref:DEC-host-sdk-direct-haskell
import {createFormatter} from '../pilot-browser.mjs';
const source = document.querySelector('#source');
const button = document.querySelector('#format');
const status = document.querySelector('#status');
let formatter;
button.addEventListener('click', async () =>
{
  button.disabled = true;
  try
  {
    formatter ??= await createFormatter();
    const response = await formatter.format({
      sources: [{path: 'example.lawspec', content: source.value}],
    });
    if (response.diagnostics.length)
      status.textContent = JSON.stringify(response.diagnostics, null, 2);
    else
    {
      source.value = response.formattedSources[0].content;
      status.textContent = 'Formatted locally in the Haskell component.';
    }
  }
  catch (error)
  {
    status.textContent = `${error.code ?? 'failed'}: ${error.message}`;
  }
  finally
  {
    button.disabled = false;
  }
});
addEventListener('pagehide', () => formatter?.close());
