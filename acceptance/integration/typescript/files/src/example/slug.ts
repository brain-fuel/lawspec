export const normalize = (x: string) => x.replaceAll(" ", "-");
export const referenceNormalize = (x: string) => x.split(" ").join("-");
