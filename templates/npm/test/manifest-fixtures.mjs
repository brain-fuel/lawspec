import {writeManifest} from '../component.mjs';
export {parseManifest} from '../component.mjs';

export const configEDN = value => writeManifest({...value, component: {name: 'example', version: '0.1.0', ...value.component}});
export const packageEDN = ({name, version, ...value}) => writeManifest({manifestVersion: 1, package: {name, version}, languageProfile: '1.0-rc.2', ...value});
