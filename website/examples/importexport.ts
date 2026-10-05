import lodash from "lodash";
import bar from "./bar";
import * as ns from "./ns";

export const x = 1;

export function f() {}

export { x, f as g };
export default f;
