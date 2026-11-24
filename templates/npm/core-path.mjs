// The core speaks absolute POSIX paths only (docs/reference/host-effects.md).
// On Windows the host presents a path to it as a POSIX path whose first
// segment is the drive: C:\Users\me is /C:/Users/me, and the UNC path
// \\server\share\dir is //server/share/dir. The same mapping as
// hosts/go/internal/effects/winpath.go. Both functions take the platform as
// a parameter, so that they are checked on every host; on any platform but
// win32 they are the identity. ref:DEC-host-effect-abi

const isLetter = character => /^[A-Za-z]$/.test(character);

// The drive letter, upper-cased, and the rest after it and the colon, or
// null when a path does not start with a drive letter and a colon.
function drivePrefix(file)
{
  if (file.length >= 2 && file[1] === ':' && isLetter(file[0]))
  {
    return {drive: file[0].toUpperCase(), rest: file.slice(2)};
  }
  return null;
}

const forward = file =>
{
  const slashed = file.replaceAll('\\', '/');
  return slashed.startsWith('//?/') ? slashed.slice(4) : slashed;
};

// A native path in the form the core is given: forward slashes, and a drive
// as the first segment.
export function corePath(platform, file)
{
  if (platform !== 'win32')
  {
    return file;
  }
  const slashed = forward(file);
  const found = drivePrefix(slashed);
  if (found !== null)
  {
    return `/${found.drive}:${found.rest === '' ? '/' : found.rest}`;
  }
  return slashed;
}

// A path of the core's form, or a Windows path in any spelling, as the file
// APIs of the operating system take it.
export function nativePath(platform, file)
{
  if (platform !== 'win32')
  {
    return file;
  }
  let slashed = forward(file);
  if (
    slashed.length >= 3 &&
    slashed[0] === '/' &&
    drivePrefix(slashed.slice(1))
  )
  {
    slashed = slashed.slice(1);
  }
  const found = drivePrefix(slashed);
  if (found !== null)
  {
    return `${found.drive}:${found.rest === '' ? '/' : found.rest}`;
  }
  return slashed;
}
