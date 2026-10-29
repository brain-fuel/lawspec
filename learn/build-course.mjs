// Generate the served course and tutor material from executable source projects.
// ref:DEC-learn-executable-story
import {readFile, readdir, realpath, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('./', import.meta.url));
const languages = ['fsharp', 'typescript', 'javascript'];
const allowed = {
  fsharp: ['Solution.fs'],
  typescript: ['Solution.ts'],
  javascript: ['Solution.js'],
};
const json = async file => JSON.parse(await readFile(file, 'utf8'));
/** Resolve inherited exercise files without copying source into the authored lesson prose. ref:DEC-learn-executable-story */
async function project(relative, seen = new Set())
{
  const directory = await realpath(path.resolve(root, relative));
  if (
    !directory.startsWith(path.join(root, 'exercises') + path.sep) ||
    seen.has(directory)
  )
  {
    throw new Error('Invalid or cyclic exercise project: ' + relative);
  }
  const next = new Set(seen).add(directory),
    entries = await readdir(directory);
  const config = entries.includes('project.json')
    ? await json(path.join(directory, 'project.json'))
    : {};
  const previous = config.extends
    ? await project(
        path.relative(root, path.resolve(directory, config.extends)),
        next,
      )
    : null;
  const projects = previous
    ? structuredClone(previous.projects)
    : Object.fromEntries(languages.map(lang => [lang, {}]));
  const sources = previous
    ? structuredClone(previous.sources)
    : Object.fromEntries(languages.map(lang => [lang, {}]));
  for (const language of languages)
  {
    const ownFiles = await readdir(path.join(directory, language)).catch(
      error =>
      {
        if (error.code === 'ENOENT')
        {
          return [];
        }
        throw error;
      },
    );
    if (ownFiles.some(name => !allowed[language].includes(name)))
    {
      throw new Error(
        'Unrecognized source file in ' + relative + '/' + language,
      );
    }
    for (const [folder, names] of [
      ['', ['Tests.lawspec', 'Harness.lawspec']],
      [language, allowed[language]],
    ])
    {
      for (const name of names)
      {
        const file = path.join(directory, folder, name);
        try
        {
          const source = await readFile(file, 'utf8');
          projects[language][name] = source;
          sources[language][name] = path.relative(root, file);
        }
        catch (error)
        {
          if (error.code !== 'ENOENT')
          {
            throw error;
          }
        }
      }
    }
    const required = [...allowed[language], 'Tests.lawspec', 'Harness.lawspec'];
    if (required.some(name => !projects[language][name]))
    {
      throw new Error('Incomplete project ' + relative + '/' + language);
    }
    projects[language] = Object.fromEntries(
      required.map(name => [name, projects[language][name]]),
    );
  }
  return {projects, sources};
}
/** Build every story scene from its complete executable project, retaining exact source provenance. ref:DEC-learn-executable-story */
export async function buildCourse()
{
  const course = await json(path.join(root, 'course.json'));
  const previous = await json(
    path.join(root, 'archive/preview-4-before-english-names.json'),
  );
  const navigation = course.navigation?.flatMap(group => group.lessons) ?? [];
  if (
    navigation.length !== course.lessonOrder.length ||
    new Set(navigation).size !== navigation.length ||
    navigation.some(id => !course.lessonOrder.includes(id))
  )
  {
    throw new Error(
      'Course outline must include every authored lesson exactly once',
    );
  }
  const lessons = [];
  for (const id of course.lessonOrder)
  {
    const lesson = await json(path.join(root, 'lessons', id + '.json'));
    for (const stage of lesson.stages)
    {
      const built = await project(stage.project);
      stage.projects = built.projects;
      stage.sources = built.sources;
      stage.previousProjects = previous.lessons
        .find(row => row.id === id)
        ?.stages.find(row => row.id === stage.id)?.projects;
      if (
        !['Tests', 'Solution'].includes(stage.editor) ||
        !stage.story?.length ||
        !stage.harnessNotes?.length ||
        !['examples', 'sample', 'all'].includes(stage.run.mode) ||
        !['passed', 'failed'].includes(stage.run.expect)
      )
      {
        throw new Error('Incomplete story scene ' + id + '/' + stage.id);
      }
      for (const language of languages)
      {
        const file =
          stage.focus === 'Solution'
            ? allowed[language][0]
            : stage.focus === 'Tests'
              ? 'Tests.lawspec'
              : stage.focus;
        if (!stage.projects[language][file])
        {
          throw new Error(
            'Missing scene focus ' + id + '/' + stage.id + '/' + file,
          );
        }
      }
    }
    lesson.projects = lesson.stages[0].projects;
    const solution = await project(lesson.solutionProject);
    lesson.solutions = solution.projects;
    lesson.solutionSources = solution.sources;
    lessons.push(lesson);
  }
  delete course.lessonOrder;
  return {
    ...course,
    codeLicenses: [
      {
        name: 'Wlaschin example code (MIT)',
        source: 'https://fsharpforfunandprofit.com/about/license/',
        text: await readFile(
          path.join(root, 'exercises/WLASCHIN-LICENSE.txt'),
          'utf8',
        ),
      },
    ],
    lessons,
  };
}
if (process.argv[1] === fileURLToPath(import.meta.url))
{
  const content = JSON.stringify(await buildCourse(), null, 2) + '\n';
  if (process.argv.includes('--stdout'))
  {
    process.stdout.write(content);
  }
  else
  {
    await writeFile(path.join(root, 'curriculum.json'), content);
  }
}
