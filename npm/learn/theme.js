// Apply the saved appearance before styles and Monaco load, avoiding a light flash.
// ref:DEC-learn-theme
(() =>
{
  const key = 'lawspec-learn:theme';
  const root = document.documentElement;
  const system = matchMedia('(prefers-color-scheme: dark)');
  const valid = value =>
    ['auto', 'light', 'dark'].includes(value) ? value : 'auto';
  let preference = 'auto';
  try
  {
    preference = valid(localStorage.getItem(key));
  }
  catch
  {
    /* Storage may be unavailable; keep the in-session choice. */
  }
  const apply = () =>
  {
    root.dataset.themePreference = preference;
    root.dataset.theme =
      preference === 'auto' ? (system.matches ? 'dark' : 'light') : preference;
    for (const input of document.querySelectorAll('#theme-picker input'))
    {
      input.checked = input.value === preference;
    }
    document.dispatchEvent(new Event('lawspec-theme-change'));
  };
  apply();
  system.addEventListener('change', () =>
  {
    if (preference === 'auto')
    {
      apply();
    }
  });
  window.addEventListener('storage', event =>
  {
    if (event.key === key || event.key === null)
    {
      preference = valid(event.newValue);
      apply();
    }
  });
  const connect = () =>
  {
    apply();
    document
      .getElementById('theme-picker')
      .addEventListener('change', event =>
      {
        if (!event.target.matches('input[type=radio]'))
        {
          return;
        }
        preference = valid(event.target.value);
        try
        {
          localStorage.setItem(key, preference);
        }
        catch
        {
          /* The chosen theme still works without persistence. */
        }
        apply();
      });
  };
  if (document.readyState === 'loading')
  {
    document.addEventListener('DOMContentLoaded', connect, {once: true});
  }
  else
  {
    connect();
  }
})();
