// ref:DEC-learn-course-hierarchy
import {execute} from './sandbox.mjs';
import {expectationProblems} from './story.mjs';
import {describeCheck, runSummary, observedCall} from './presentation.mjs';
import {
  openStore,
  draftKey,
  courseVersion,
  refreshProvidedLaws,
} from './store.mjs';
import {monaco} from './vendor/editor.mjs';
const $ = id => document.getElementById(id);
const node = (tag, text, attributes = {}) =>
{
  const el = document.createElement(tag);
  el.textContent = text;
  for (const [key, value] of Object.entries(attributes))
  {
    el.setAttribute(key, value);
  }
  return el;
};
const started = performance.now();
const runScopes = {
  all: 'All checks',
  examples: 'Examples + boundaries',
  sample: 'Sampled properties',
};
globalThis.MonacoEnvironment = {
  getWorker: () =>
    new Worker(new URL('./vendor/editor-worker.js', import.meta.url)),
};
const course = await (
  await fetch(new URL('./curriculum.json', import.meta.url))
).json();
let store;
try
{
  store = await openStore();
}
catch (error)
{
  $('message').textContent = 'Draft storage is unavailable: ' + error.message;
  throw error;
}
const params = new URLSearchParams(location.hash.slice(1));
let lesson =
  (params.get('course') === course.version &&
    course.lessons.find(row => row.id === params.get('lesson'))) ||
  course.lessons[0];
let sceneIndex =
  params.get('course') === course.version
    ? Math.max(
        0,
        lesson.stages.findIndex(row => row.id === params.get('scene')),
      )
    : 0;
const scene = () => lesson.stages[sceneIndex];
const key = () => draftKey(lesson.id, track, language, scene().id);
const focusFile = () =>
  ['Solution', 'Tests'].includes(scene().focus)
    ? scene().focus === 'Tests'
      ? 'Tests.lawspec'
      : 'Solution.' +
        {fsharp: 'fs', typescript: 'ts', javascript: 'js'}[language]
    : scene().focus;
let language = ['fsharp', 'typescript', 'javascript'].includes(
  params.get('language'),
)
  ? params.get('language')
  : 'fsharp';
let track = course.tracks.some(row => row.id === params.get('track'))
  ? params.get('track')
  : 'shared';
let draft,
  currentFile,
  model,
  suppress = false,
  controller,
  worker,
  formatWorker,
  runId = 0,
  lastRun,
  lastFailure,
  generated = [],
  hint = 0,
  saveQueue = Promise.resolve();
let replacementFiles = null;
function forgetReplacement()
{
  replacementFiles = null;
  $('undo-replacement').hidden = true;
}
function replaceFiles(files)
{
  if (
    !Object.entries(files).every(
      ([name, content]) => draft.files[name] === content,
    )
  )
  {
    replacementFiles = structuredClone(draft.files);
    $('undo-replacement').hidden = false;
  }
  draft.files = structuredClone(files);
}
const editor = monaco.editor.create($('editor'), {
  theme: 'lawspec-' + document.documentElement.dataset.theme,
  fontFamily: '"Atkinson Hyperlegible Mono", monospace',
  fontSize: 14,
  lineHeight: 22,
  fontLigatures: false,
  minimap: {enabled: false},
  automaticLayout: true,
  scrollBeyondLastLine: false,
  tabSize: 4,
  wordWrap: 'on',
  accessibilitySupport: 'auto',
});
// Theme changes preserve drafts, selection and execution results. ref:DEC-learn-theme
document.addEventListener('lawspec-theme-change', () =>
{
  monaco.editor.setTheme('lawspec-' + document.documentElement.dataset.theme);
  if (generatedSelection)
  {
    awaitGenerated(generatedSelection);
  }
  renderStoryCode();
});
let generatedSelection,
  colorization = 0,
  storyColorization = 0;
document.fonts.load('400 14px "Atkinson Hyperlegible Mono"').then(() =>
{
  monaco.editor.remeasureFonts();
  editor.layout();
});
function message(text, error = false)
{
  $('message').textContent = text;
  $('message').className = error ? 'error' : '';
}
function busy(value)
{
  for (const id of [
    'run',
    'examples',
    'sample',
    'load-stage',
    'solution',
    'complete',
  ])
  {
    $(id).disabled = value;
  }
  $('cancel').disabled = !value;
  $('cancel').hidden = !value;
  $('run').setAttribute('aria-busy', String(value));
}
function clearExecution()
{
  $('teaching-feedback').hidden = true;
  lastRun = null;
  lastFailure = null;
  $('replay-hint').textContent = '';
  generated = [];
  generatedSelection = undefined;
  $('generated-files').replaceChildren();
  $('generated').textContent = '';
  $('replay').disabled = true;
  $('regression').disabled = true;
  $('outcomes').replaceChildren();
  $('diagnostics').textContent = '';
}
function invalidate()
{
  clearExecution();
  $('completion').textContent = '';
  draft.completed = false;
  $('result-status').textContent = 'Edited · rerun required';
  $('outcomes').replaceChildren();
  $('diagnostics').textContent = '';
  controller?.abort();
}
function save({required = false} = {})
{
  const identity = key(),
    value = structuredClone(draft);
  $('save-status').textContent = 'Saving…';
  saveQueue = saveQueue
    .catch(() =>
    {})
    .then(() => store.put(identity, value))
    .then(() =>
    {
      $('save-status').textContent = 'Saved on device';
    })
    .catch(error =>
    {
      $('save-status').textContent = 'Save failed';
      message(error.message, true);
      if (required) throw error;
    });
  return saveQueue;
}
function languageFor(name)
{
  return name.endsWith('.lawspec')
    ? 'lawspec'
    : name.endsWith('.fs')
      ? 'fsharp'
      : name.endsWith('.ts')
        ? 'typescript'
        : /\.m?js$/.test(name)
          ? 'javascript'
          : name.endsWith('.json')
            ? 'json'
            : 'plaintext';
}
function selectFile(name)
{
  currentFile = name;
  suppress = true;
  if (model)
  {
    editor.setModel(null);
    model.dispose();
  }
  model = monaco.editor.createModel(draft.files[name], languageFor(name));
  editor.setModel(model);
  $('current-file').textContent = name;
  $('harness-help').hidden = name !== 'Harness.lawspec';
  $('harness-explanation').replaceChildren(
    ...[
      course.harnessExplanation.role,
      'This walkthrough describes the supplied harness for this step. Your edited source above determines the inputs actually used.',
      ...scene().harnessNotes,
      course.harnessExplanation.declaration,
      course.harnessExplanation.scope,
      course.harnessExplanation.execution,
    ].map(text => node('p', text)),
  );
  for (const button of $('files').querySelectorAll('button'))
  {
    const selected = button.dataset.file === name;
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
  }
  editor
    .getDomNode()
    .setAttribute('aria-labelledby', 'file-' + name.replaceAll('.', '-'));
  editor.updateOptions({
    ariaLabel:
      name +
      ' · ' +
      {fsharp: 'F#', typescript: 'TypeScript', javascript: 'JavaScript'}[
        language
      ] +
      ' project',
  });
  model.onDidChangeContent(() =>
  {
    if (suppress)
    {
      return;
    }
    draft.files[currentFile] = model.getValue();
    forgetReplacement();
    invalidate();
    renderStoryCode();
    save();
  });
  suppress = false;
}
function suppliedScene()
{
  return (
    Number($('seed').value) === (scene().run.seed ?? 424242) &&
    Object.entries(scene().projects[language]).every(
      ([name, content]) => draft.files[name] === content,
    )
  );
}
async function renderStoryCode()
{
  if (!draft)
  {
    return;
  }
  const revision = ++storyColorization,
    file = focusFile(),
    content = draft.files[file];
  $('story-file').textContent = file + ' · open in editor';
  $('story-state').textContent = suppliedScene()
    ? 'Source for this step'
    : 'Your edited version · the story describes the resettable example';
  $('expect').textContent = suppliedScene()
    ? scene().expect
    : 'You changed this project. Run to observe your code; Reset this step reproduces the supplied example.';
  const colored = await monaco.editor.colorize(content, languageFor(file), {});
  if (revision === storyColorization)
  {
    $('story-code').innerHTML = colored;
  }
}
function showStage()
{
  const stage = scene();
  $('symbol').hidden = !stage.symbol;
  $('symbol').textContent = stage.symbol ?? '';
  for (const button of $('stage').querySelectorAll('button'))
  {
    button.setAttribute(
      'aria-current',
      Number(button.dataset.stage) === sceneIndex ? 'step' : 'false',
    );
  }
  $('story').replaceChildren(...stage.story.map(text => node('p', text)));
  for (const id of ['action', 'reason', 'expect', 'recovery'])
  {
    $(id).textContent = stage[id];
  }
  $('stage-title').textContent = stage.title;
  $('code-step').textContent =
    `Step ${sceneIndex + 1} of ${lesson.stages.length} · ${stage.title}`;
  $('explanation').textContent =
    (stage.syntax ??
      'Tests and generation strategies are written in LawSpec. Only the implementation changes language.') +
    ' ' +
    lesson.implementationSyntax[language];
  $('naming-guide').textContent = course.namingGuide;
  $('run-scope').textContent = runScopes[stage.run.mode];
  $('examples').hidden = stage.run.mode === 'examples';
  $('sample').hidden = stage.run.mode !== 'all';
  document.querySelector('.alternate-runs').hidden =
    $('examples').hidden && $('sample').hidden;
  $('previous-scene').disabled = sceneIndex === 0 || Boolean(controller);
  $('next-scene').disabled =
    sceneIndex === lesson.stages.length - 1 || Boolean(controller);
  renderStoryCode();
}
function lockNavigation(value)
{
  for (const button of document.querySelectorAll(
    '#lessons button,#languages button,#files button,#previous-scene,#next-scene',
  ))
  {
    button.disabled = value;
  }
}
async function navigate(
  change,
  {preserveView = false, preserveFile = false} = {},
)
{
  const view = document.documentElement.dataset.workspaceView,
    position = $('lesson-reader').scrollTop,
    selectedFile = preserveFile ? currentFile : undefined;
  lockNavigation(true);
  await save();
  change();
  await load(selectedFile);
  setWorkspaceView(preserveView ? view : 'read');
  $('lesson-reader').scrollTop = preserveView ? position : 0;
  if (!preserveView)
  {
    $('stage-title').focus({preventScroll: true});
  }
}
async function load(selectedFile)
{
  forgetReplacement();
  lockNavigation(true);
  $('lesson-reader').scrollTop = 0;
  $('code-panel').querySelector('.results').scrollTop = 0;
  controller?.abort();
  await saveQueue;
  draft = (await store.get(key())) ?? {
    files: structuredClone(scene().projects[language]),
    stage: sceneIndex,
    completed: false,
  };
  if (!draft.files)
  {
    throw new Error('Invalid saved draft');
  }
  const refreshed = refreshProvidedLaws(
    draft,
    scene().previousProjects?.[language],
    scene().projects[language],
  );
  lastRun = null;
  lastFailure = null;
  hint = 0;
  generated = [];
  generatedSelection = undefined;
  $('outcomes').replaceChildren();
  $('teaching-feedback').hidden = true;
  $('generated-files').replaceChildren();
  $('generated').textContent = '';
  $('diagnostics').textContent = '';
  $('replay').disabled = true;
  $('regression').disabled = true;
  $('hint-text').textContent = '';
  $('title').textContent = lesson.title;
  $('lesson-number').textContent =
    `STEP ${sceneIndex + 1} OF ${lesson.stages.length}`;
  for (const id of ['slogan', 'vision', 'news', 'contributions'])
  {
    $(id).textContent = lesson[id];
  }
  renderOutline();
  $('languages').replaceChildren(
    ...[
      ['fsharp', 'F#', 'F#'],
      ['typescript', 'TypeScript', 'TS'],
      ['javascript', 'JavaScript', 'JS'],
    ].map(([id, label, short]) =>
    {
      const button = node('button', '', {
        role: 'tab',
        id: 'language-' + id,
        'aria-label': label,
        'aria-selected': String(language === id),
        tabindex: language === id ? '0' : '-1',
        'aria-controls': 'editor',
        title: label,
      });
      button.append(
        node('span', label, {class: 'language-long'}),
        node('span', short, {class: 'language-short', 'aria-hidden': 'true'}),
      );
      button.onclick = () =>
        navigate(
          () =>
          {
            language = id;
          },
          {preserveView: true, preserveFile: true},
        );
      return button;
    }),
  );
  const ext = {fsharp: 'fs', typescript: 'ts', javascript: 'js'}[language];
  const views = [
    ['Tests.lawspec', 'Laws'],
    [`Solution.${ext}`, 'Solution'],
    ['Harness.lawspec', 'Harness'],
  ];
  const preferred = selectedFile?.startsWith('Solution.')
    ? 'Solution.' + ext
    : (selectedFile ??
      (scene().editor === 'Tests' ? 'Tests.lawspec' : 'Solution.' + ext));
  $('files').replaceChildren(
    ...views.map(([name, label]) =>
    {
      const button = node('button', label, {
        type: 'button',
        role: 'tab',
        id: 'file-' + name.replaceAll('.', '-'),
        'data-file': name,
        'aria-controls': 'editor',
        title: name,
      });
      button.onclick = () => selectFile(name);
      return button;
    }),
  );
  $('attribution').replaceChildren(
    ...lesson.attribution.map(row =>
    {
      const p = node('p', '');
      p.append(
        node('a', row.title, {
          href: row.url,
          target: '_blank',
          rel: 'noopener',
        }),
        node('span', ' — ' + row.use),
      );
      return p;
    }),
  );
  $('execution-label').textContent =
    language === 'fsharp'
      ? 'F# → Fable → JavaScript · LawSpec JS harness + fast-check'
      : 'JavaScript execution · LawSpec JS harness + fast-check';
  $('completion').textContent = draft.completed
    ? ' Learning milestone saved.'
    : '';
  $('result-status').textContent = 'Ready · no current run';
  message(
    refreshed
      ? 'The unchanged starter Laws and Harness now use English names. Your implementation and milestones were kept. Predict the result, then run.'
      : 'Predict the result for this step, then run the selected checks.',
  );
  $('save-status').textContent = 'Saved on device';
  $('run-options').open = false;
  $('replay-hint').textContent = '';
  $('saved-notebook').hidden = track === 'shared';
  $('saved-notebook').textContent =
    'Current saved notebook: ' +
    course.tracks.find(row => row.id === track).title +
    '.';
  selectFile(preferred);
  lockNavigation(false);
  showStage();
  history.replaceState(
    null,
    '',
    '#' +
      new URLSearchParams({
        course: course.version,
        lesson: lesson.id,
        scene: scene().id,
        language,
        track,
      }),
  );
}
/** Present authored lessons and the current lesson's steps as one course outline. ref:DEC-learn-course-hierarchy */
function renderOutline()
{
  const groups = course.navigation.map(group =>
  {
    const section = node('section', '', {
      'aria-labelledby': 'outline-' + group.id,
    });
    section.append(node('h3', group.title, {id: 'outline-' + group.id}));
    const list = node('ol', '');
    for (const id of group.lessons)
    {
      const row = course.lessons.find(item => item.id === id),
        active = row === lesson,
        index = course.lessons.indexOf(row),
        item = node('li', '');
      const button = node('button', '', {
        'data-lesson': id,
        'aria-current': active ? 'true' : 'false',
        class: active ? 'active' : '',
      });
      button.append(
        node('span', String(index + 1).padStart(2, '0'), {
          class: 'lesson-index',
        }),
        node('span', row.title),
      );
      button.onclick = () =>
        navigate(() =>
        {
          lesson = row;
          sceneIndex = 0;
        });
      item.append(button);
      if (active)
      {
        const steps = node('ol', '', {
          id: 'stage',
          'aria-label': 'Steps in ' + row.title,
        });
        for (const [i, step] of row.stages.entries())
        {
          const li = node('li', ''),
            control = node('button', '', {
              'data-stage': String(i),
              'aria-current': i === sceneIndex ? 'step' : 'false',
            });
          control.append(
            node('span', String(i + 1), {class: 'step-number'}),
            node('span', step.title),
          );
          control.onclick = () =>
            navigate(() =>
            {
              sceneIndex = i;
            });
          li.append(control);
          steps.append(li);
        }
        item.append(steps);
      }
      list.append(item);
    }
    section.append(list);
    return section;
  });
  $('lessons').replaceChildren(...groups);
}
/** Switch compact views without replacing either pane or losing the current editor model. ref:DEC-learn-workspace-focus */
function setWorkspaceView(view)
{
  document.documentElement.dataset.workspaceView = view;
  for (const button of $('workspace-views').querySelectorAll('[role=tab]'))
  {
    const active = button.dataset.view === view;
    button.setAttribute('aria-selected', String(active));
    button.tabIndex = active ? 0 : -1;
  }
}
for (const button of $('workspace-views').querySelectorAll('[data-view]'))
{
  button.onclick = () => setWorkspaceView(button.dataset.view);
}
$('workspace-views').addEventListener('keydown', event =>
{
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key))
  {
    return;
  }
  const tabs = [...$('workspace-views').querySelectorAll('[role=tab]')],
    index = tabs.indexOf(document.activeElement);
  if (index < 0)
  {
    return;
  }
  event.preventDefault();
  const next =
    event.key === 'Home'
      ? 0
      : event.key === 'End'
        ? tabs.length - 1
        : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) %
          tabs.length;
  tabs[next].click();
  tabs[next].focus();
});
$('course-status').textContent = course.checkpoint;
$('roadmap').append(...course.roadmap.map(text => node('li', text)));
$('planned-tracks').append(
  ...course.tracks
    .filter(row => row.status === 'after review')
    .map(row =>
    {
      const item = node('li', '');
      item.append(node('b', row.title), node('span', ' — ' + row.scope));
      return item;
    }),
);
$('future-attribution').append(
  node('h3', 'Further reading'),
  ...course.futureAttribution.map(row =>
  {
    const p = node('p', '');
    p.append(
      node('a', row.title, {href: row.url, target: '_blank', rel: 'noopener'}),
      node('span', ' — ' + row.use),
    );
    return p;
  }),
);
for (const group of [$('files'), $('languages')])
{
  group.addEventListener('keydown', async event =>
  {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key))
    {
      return;
    }
    const tabs = [...group.querySelectorAll('[role=tab]:not(:disabled)')];
    const index = tabs.indexOf(document.activeElement);
    if (index < 0)
    {
      return;
    }
    event.preventDefault();
    const next =
      event.key === 'Home'
        ? 0
        : event.key === 'End'
          ? tabs.length - 1
          : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) %
            tabs.length;
    await tabs[next].onclick();
    group.querySelector('[aria-selected="true"]')?.focus();
  });
}
$('story-file').onclick = () =>
{
  selectFile(focusFile());
  setWorkspaceView('code');
  editor.focus();
};
$('previous-scene').onclick = () =>
  navigate(() =>
  {
    sceneIndex = Math.max(0, sceneIndex - 1);
  });
$('next-scene').onclick = () =>
  navigate(() =>
  {
    sceneIndex = Math.min(lesson.stages.length - 1, sceneIndex + 1);
  });
$('load-stage').onclick = () =>
{
  replaceFiles(scene().projects[language]);
  $('seed').value = String(scene().run.seed ?? 424242);
  invalidate();
  selectFile(focusFile());
  showStage();
  save();
  message('This step’s source restored. Predict its result, then run.');
};
$('undo-replacement').onclick = () =>
{
  if (!replacementFiles)
  {
    return;
  }
  draft.files = replacementFiles;
  forgetReplacement();
  invalidate();
  selectFile(currentFile);
  showStage();
  save();
  message(
    'Your previous files are restored, including any kept regression cases. Rerun to observe their current results.',
  );
};
$('hint').onclick = () =>
{
  $('hint-text').textContent =
    lesson.hints[Math.min(hint++, lesson.hints.length - 1)];
};
$('solution').onclick = async () =>
{
  if (sceneIndex !== lesson.stages.length - 1)
  {
    await navigate(() =>
    {
      sceneIndex = lesson.stages.length - 1;
    });
  }
  replaceFiles(lesson.solutions[language]);
  invalidate();
  selectFile(
    Object.keys(draft.files).find(name => name.startsWith('Solution.')),
  );
  showStage();
  await save();
  setWorkspaceView('code');
  message(
    'Complete solution loaded in the final step. Run the unchanged checks and compare the implementation with the failing version.',
  );
};
$('seed').onchange = () =>
{
  invalidate();
  renderStoryCode();
  message('Seed changed. Run again to get current evidence.');
};
/** Keep formatting and compilation cancellable, with separate worker lifetimes. ref:DEC-learn-format-before-run */
function requestWorker(kind, request, signal)
{
  if (signal.aborted)
    return Promise.reject(new DOMException(kind + ' cancelled', 'AbortError'));
  const formatting = kind === 'Formatting';
  let activeWorker;
  if (formatting)
  {
    activeWorker = formatWorker ??= new Worker(
      new URL('./format-worker.mjs', import.meta.url),
      {type: 'module'},
    );
  }
  else
  {
    activeWorker = worker ??= new Worker(
      new URL('./compile-worker.mjs', import.meta.url),
      {type: 'module'},
    );
  }
  const terminate = () =>
  {
    activeWorker.terminate();
    if (formatting)
    {
      formatWorker = null;
    }
    else
    {
      worker = null;
    }
  };
  return new Promise((resolve, reject) =>
  {
    const id = ++runId;
    const clean = () =>
    {
      signal.removeEventListener('abort', abort);
      activeWorker.removeEventListener('message', listen);
      activeWorker.removeEventListener('error', error);
      clearTimeout(timer);
    };
    const abort = () =>
    {
      clean();
      terminate();
      reject(new DOMException(kind + ' cancelled', 'AbortError'));
    };
    const listen = ({data}) =>
    {
      if (data.id !== id)
      {
        return;
      }
      if (data.progress)
      {
        message(data.progress);
        return;
      }
      clean();
      data.error ? reject(new Error(data.error)) : resolve(data.result);
    };
    const error = event =>
    {
      clean();
      terminate();
      reject(new Error(event.message));
    };
    const timer = setTimeout(() =>
    {
      clean();
      terminate();
      reject(new Error(kind + ' timed out; your draft is saved.'));
    }, 120000);
    signal.addEventListener('abort', abort, {once: true});
    activeWorker.addEventListener('message', listen);
    activeWorker.addEventListener('error', error);
    activeWorker.postMessage({...request, id});
  });
}
function renderResult(compiled, result, elapsed)
{
  $('code-panel').querySelector('.results').scrollTop = 0;
  $('diagnostics').textContent = JSON.stringify(
    {
      diagnostics: compiled.diagnostics,
      mandatoryDefinitionValidation: compiled.definitionValidation,
      compilerEvidence: compiled.evidence,
      execution: compiled.execution,
      harnessReports: result?.harnessReports,
      executedChecks: result?.tests,
      timingMilliseconds: Math.round(elapsed),
    },
    null,
    2,
  );
  generated = compiled.generated ?? [];
  $('generated-files').replaceChildren(
    ...generated.map(row =>
    {
      const button = node('button', row.path, {type: 'button'});
      button.onclick = () => awaitGenerated(row);
      return button;
    }),
  );
  awaitGenerated(generated[0]);
  $('outcomes').replaceChildren();
  if (!result)
  {
    $('result-status').textContent = 'Checks could not run';
    $('diagnostic-panel').open = true;
    message(
      'Compilation did not produce executable checks. Read the diagnostics and repair the source.',
      true,
    );
    return;
  }
  $('result-status').textContent = result.ok
    ? 'Checks passed'
    : 'Check the failure';
  message(runSummary(result, elapsed));
  for (const row of result.tests)
  {
    const check = describeCheck(row.name, compiled.checks);
    const line = node(
      'p',
      `${row.ok ? '✓' : '×'} ${check.label} · ${row.status}`,
      {
        class: row.ok ? 'passed' : 'failed',
        title: row.name,
      },
    );
    line.append(node('span', ' · ' + check.kind, {class: 'muted'}));
    $('outcomes').append(line);
    if (row.calls?.length && (!row.ok || !result.properties.length))
    {
      $('outcomes').append(
        node(
          'pre',
          row.calls
            .map(call => observedCall(compiled.binding, call, language))
            .join('\n'),
        ),
      );
    }
    if (row.error)
    {
      const error = node('details', '');
      error.append(node('summary', 'Failure details'), node('pre', row.error));
      $('outcomes').append(error);
      if (row.status !== 'failed')
      {
        $('outcomes').append(node('p', row.error));
      }
    }
  }
  for (const row of result.properties)
  {
    const check = describeCheck(row.test, compiled.checks);
    $('outcomes').append(
      node(
        'p',
        `${check.label}: ${row.numRuns} generated trials; ${row.numShrinks} smaller failing cases kept · ${row.status}`,
        {
          class: row.status === 'passed' ? 'passed' : 'failed',
        },
      ),
    );
    if (row.counterexample)
    {
      $('outcomes').append(
        node(
          'h3',
          row.counterexampleDomain === 'law-inputs'
            ? 'Failing input after shrinking'
            : 'Failing generator representation',
        ),
      );
      $('outcomes').append(
        node('pre', JSON.stringify(row.inputs ?? row.counterexample, null, 2)),
      );
      const trace = node('details', '');
      trace.append(
        node('summary', 'How the failure was reduced'),
        node(
          'pre',
          JSON.stringify(
            {
              seed: row.seed,
              replayPath: row.path,
              failedShrinkCandidates: row.failures,
              observations: row.observations,
            },
            null,
            2,
          ),
        ),
      );
      $('outcomes').append(trace);
    }
  }
  if (result.samples?.length)
  {
    $('outcomes').append(
      node(
        'p',
        'First generated inputs tried: ' + JSON.stringify(result.samples),
      ),
    );
  }
  if (result.sampled && result.coverage)
  {
    const coverage = node('details', '');
    coverage.append(
      node('summary', 'Which inputs were tried?'),
      node(
        'p',
        'Counts summarize values observed during property evaluation, including shrink attempts.',
      ),
      node('pre', JSON.stringify(result.coverage, null, 2)),
    );
    $('outcomes').append(coverage);
  }
  $('teaching-feedback').hidden = false;
  if (suppliedScene())
  {
    const problems = expectationProblems(result, scene().run);
    $('teaching-feedback').textContent = problems.length
      ? 'This run differs from the supplied scene’s checked observation: ' +
        problems.join(' ')
      : scene().run.expect === 'failed'
        ? 'This step is meant to reveal a failing check. The failure above is the observation to explain, not a request to make every test green yet.'
        : 'This run matches the supplied step’s expected passed outcome. A pass describes the checks and inputs tried.';
  }
  else
  {
    $('teaching-feedback').textContent =
      'These results belong to your saved or edited files. The supplied step’s prediction may differ; explain what your checks actually observed.';
  }
  lastRun = {compiled, result, mode: result.mode};
  const failure = result.sampled?.counterexample ? result.sampled : null;
  if (failure)
  {
    $('run-options').open = true;
    $('replay-hint').textContent = ' · failure ready to replay';
    lastFailure = {...failure, files: JSON.stringify(draft.files)};
    $('replay').disabled = false;
    $('regression').disabled =
      !scene().regression || failure.counterexampleDomain !== 'law-inputs';
  }
}
async function run(mode, path = '', replayTest = null)
{
  if (controller)
  {
    return;
  }
  const active = new AbortController();
  controller = active;
  busy(true);
  $('run-scope').textContent = runScopes[mode];
  clearExecution();
  $('outcomes').replaceChildren();
  $('result-status').textContent = 'Running';
  message(
    'Compiling on your device. The first run loads the packaged compilers…',
  );
  const began = performance.now();
  try
  {
    $('result-status').textContent = 'Formatting';
    message('Formatting your files on this device before running…');
    const formatted = await requestWorker(
      'Formatting',
      {files: structuredClone(draft.files)},
      active.signal,
    );
    if (active.signal.aborted)
    {
      return;
    }
    if (!formatted.files)
    {
      renderResult(
        {diagnostics: formatted.diagnostics},
        null,
        performance.now() - began,
      );
      $('result-status').textContent = 'Formatting failed';
      message(
        'Fix the syntax errors shown in diagnostics. Your source has not been run.',
        true,
      );
      return;
    }
    const changed = Object.entries(formatted.files).some(
      ([name, source]) => source !== draft.files[name],
    );
    draft.files = formatted.files;
    if (changed)
    {
      draft.completed = false;
      $('completion').textContent = '';
      suppress = true;
      editor.pushUndoStop();
      editor.executeEdits('format-before-run', [
        {range: model.getFullModelRange(), text: draft.files[currentFile]},
      ]);
      editor.pushUndoStop();
      suppress = false;
    }
    await save({required: true});
    if (active.signal.aborted) return;
    await renderStoryCode();
    if (active.signal.aborted) return;
    $('result-status').textContent = 'Compiling';
    message(
      'Code formatted and saved. Compiling this snapshot on your device…',
    );
    const compiled = await requestWorker(
      'Compilation',
      {
        lesson: {id: lesson.id},
        language,
        files: structuredClone(draft.files),
        mode,
        seed: Number($('seed').value),
        path,
        replayTest,
      },
      active.signal,
    );
    if (active.signal.aborted)
    {
      return;
    }
    const result = compiled.code
      ? await execute(compiled.code, {signal: active.signal})
      : null;
    if (active.signal.aborted)
    {
      return;
    }
    renderResult(compiled, result, performance.now() - began);
  }
  catch (error)
  {
    $('result-status').textContent =
      error.name === 'AbortError' ? 'Cancelled' : 'Execution incomplete';
    message(error.message, error.name !== 'AbortError');
    $('replay').disabled = true;
    $('regression').disabled = true;
  }
  finally
  {
    controller = null;
    busy(false);
    showStage();
  }
}
$('run').onclick = () => run(scene().run.mode);
$('examples').onclick = () => run('examples');
$('sample').onclick = () => run('sample');
$('cancel').onclick = () => controller?.abort();
$('replay').onclick = () =>
{
  if (lastFailure?.files === JSON.stringify(draft.files))
  {
    $('seed').value = String(lastFailure.seed);
    run('sample', lastFailure.path, lastFailure.test);
  }
};
$('regression').onclick = () =>
{
  if (!lastFailure || !scene().regression)
  {
    return;
  }
  const input = lastFailure.counterexample?.[0],
    expected = scene().regression.expected,
    fn = lastRun.compiled.binding.name;
  const literal = value =>
    Array.isArray(value)
      ? '[' + value.map(literal).join(', ') + ']'
      : String(value).toLowerCase();
  const source = draft.files['Tests.lawspec'];
  if (
    source.includes('law savedCounterexample ') ||
    source.includes('law "|keep this counterexample| ')
  )
  {
    message('A saved counterexample is already present in this step.');
    return;
  }
  const regression = `law "|keep this counterexample| is\n  definition:\n    ${fn} ${literal(input)} = ${literal(expected)}\n  end definition\nend law\n`;
  if (!/end unit\s*$/.test(source))
  {
    message('Restore the unit terminator before saving the counterexample.');
    return;
  }
  draft.files['Tests.lawspec'] = source.replace(
    /end unit\s*$/,
    regression + 'end unit\n',
  );
  forgetReplacement();
  invalidate();
  selectFile('Tests.lawspec');
  showStage();
  save();
  message(
    'The observed counterexample is saved as a concrete LawSpec claim. In Test controls, choose Run examples + boundaries to observe it before repair.',
  );
};
$('complete').onclick = () =>
{
  if (
    !lastRun?.result.ok ||
    lastRun.mode !== 'all' ||
    sceneIndex !== lesson.stages.length - 1
  )
  {
    message(
      'Finish the independent step and run all checks successfully before marking this learning milestone.',
    );
    return;
  }
  draft.completed = true;
  save();
  $('completion').textContent = ' Learning milestone saved · no proof claim.';
};
async function awaitGenerated(file)
{
  const revision = ++colorization;
  generatedSelection = file;
  if (!file)
  {
    $('generated').textContent = '';
    return;
  }
  const rendered = await monaco.editor.colorize(
    file.content,
    languageFor(file.path),
    {},
  );
  if (
    generated.includes(file) &&
    generatedSelection === file &&
    revision === colorization
  )
  {
    $('generated').innerHTML = rendered;
  }
}
$('export').onclick = async () =>
{
  try
  {
    await save({required: true});
    const url = URL.createObjectURL(
      new Blob(
        [
          JSON.stringify(
            {...(await store.export()), codeLicenses: course.codeLicenses},
            null,
            2,
          ),
        ],
        {type: 'application/json'},
      ),
    );
    const anchor = node('a', '', {
      href: url,
      download: `lawspec-learn-progress-${courseVersion}.json`,
    });
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    $('progress-status').textContent =
      'Progress backup downloaded. Keep the JSON file to restore your work on another device.';
  }
  catch (error)
  {
    $('progress-status').textContent = 'Backup failed: ' + error.message;
  }
};
$('restore').onclick = () => $('import').click();
$('import').onchange = async () =>
{
  try
  {
    const file = $('import').files[0];
    if (!file)
    {
      return;
    }
    if (file.size > 5000000)
    {
      throw new Error('Progress backup is too large');
    }
    controller?.abort();
    await saveQueue;
    await store.import(JSON.parse(await file.text()), course);
    await load();
    $('progress-status').textContent =
      'Drafts and milestones restored. Rerun checks for current results.';
    message('Progress restored. Rerun to obtain current execution evidence.');
  }
  catch (error)
  {
    $('progress-status').textContent = 'Restore failed: ' + error.message;
    message(error.message, true);
  }
  finally
  {
    $('import').value = '';
  }
};
window.addEventListener('pagehide', () =>
{
  controller?.abort();
  worker?.terminate();
  formatWorker?.terminate();
});
await load();
document.documentElement.dataset.ready = 'true';
performance.measure('learn-interface-ready', {
  start: started,
  end: performance.now(),
});
