export const add = (x: bigint,y: bigint): bigint => x+y;
export const multiply = (x: bigint,y: bigint): bigint => x*y;
export const negateValue = (x: bigint): bigint => -x;
export const maximumValue = (x: bigint,y: bigint): bigint => x>y?x:y;
export const subtractValue = (x: bigint,y: bigint): bigint => x-y;
export const divideLeft = (x: bigint,y: bigint): bigint => x-y;
export const divideRight = (x: bigint,y: bigint): bigint => x+y;
