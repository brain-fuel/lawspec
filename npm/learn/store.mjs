/** Separate the preview drafts from other course revisions in persistent storage. ref:DEC-learn-course-preview */
export const courseVersion = 'preview-4';
/** Keep each lesson, application notebook and executable language in its own saved draft. ref:DEC-learn-course-preview */
export function draftKey(lesson, track, language, scene)
{
  return [courseVersion, lesson, track, language, scene]
    .filter(value => value !== undefined)
    .join('/');
}
/** Refresh provided LawSpec files as a pair only when neither was edited; keep implementations, kept cases and milestones. ref:DEC-learn-english-names */
export function refreshProvidedLaws(draft, previous, current)
{
  const sources = ['Tests.lawspec', 'Harness.lawspec'];
  if (
    !previous ||
    !sources.every(name => draft.files[name] === previous[name])
  )
  {
    return false;
  }
  const changed = sources.some(name => draft.files[name] !== current[name]);
  for (const name of sources)
  {
    draft.files[name] = current[name];
  }
  return changed;
}
/** Save drafts locally and export one consistent snapshot; validate imports before an atomic write. ref:DEC-learn-course-preview */
export async function openStore()
{
  const db = await new Promise((resolve, reject) =>
  {
    const request = indexedDB.open('lawspec-learn', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('drafts');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  const transact = (mode, work) =>
    new Promise((resolve, reject) =>
    {
      const tx = db.transaction('drafts', mode),
        request = work(tx.objectStore('drafts'));
      tx.oncomplete = () => resolve(request.result);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  return {
    get: key => transact('readonly', store => store.get(key)),
    put: (key, value) => transact('readwrite', store => store.put(value, key)),
    async export()
    {
      return new Promise((resolve, reject) =>
      {
        const tx = db.transaction('drafts', 'readonly'),
          object = tx.objectStore('drafts');
        const rows = object.getAll(),
          keys = object.getAllKeys();
        tx.oncomplete = () =>
          resolve({
            format: 'lawspec-learn',
            version: courseVersion,
            drafts: keys.result
              .map((key, i) => ({key, value: rows.result[i]}))
              .filter(row => row.key.startsWith(courseVersion + '/')),
          });
        tx.onerror = () => reject(tx.error);
      });
    },
    async import(project, curriculum)
    {
      validateImport(project, curriculum);
      // Validate the entire file before making one atomic write transaction.
      await new Promise((resolve, reject) =>
      {
        const tx = db.transaction('drafts', 'readwrite');
        for (const row of project.drafts)
        {
          tx.objectStore('drafts').put(row.value, row.key);
        }
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
      });
    },
  };
}
/** Reject unsupported course versions, identities and file shapes before an import changes stored progress. ref:DEC-learn-course-preview */
export function validateImport(project, curriculum)
{
  if (
    project?.format !== 'lawspec-learn' ||
    project.version !== courseVersion ||
    !Array.isArray(project.drafts) ||
    project.drafts.length > 1000
  )
  {
    throw new Error('Unsupported course backup');
  }
  const keys = new Set();
  for (const {key, value} of project.drafts)
  {
    const [version, id, track, language, scene, ...extra] =
      String(key).split('/');
    const lesson = curriculum.lessons.find(row => row.id === id);
    if (
      version !== courseVersion ||
      extra.length ||
      !lesson ||
      !curriculum.tracks.some(row => row.id === track) ||
      !lesson.projects[language] ||
      !lesson.stages.some(row => row.id === scene) ||
      keys.has(key)
    )
    {
      throw new Error('Invalid draft identity');
    }
    keys.add(key);
    if (
      !value ||
      typeof value.files !== 'object' ||
      !Number.isInteger(value.stage) ||
      lesson.stages[value.stage]?.id !== scene ||
      typeof value.completed !== 'boolean'
    )
    {
      throw new Error('Invalid progress');
    }
    const expected = Object.keys(lesson.projects[language]);
    if (
      Object.keys(value.files).length !== expected.length ||
      expected.some(
        name =>
          typeof value.files[name] !== 'string' ||
          value.files[name].length > 500000,
      )
    )
    {
      throw new Error('Invalid backup files');
    }
    // Execution results are deliberately never imported as fresh evidence.
  }
}
