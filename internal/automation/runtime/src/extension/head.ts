export const completion = "__swiptCompletion";
export const hoist = "__swiptHoist";
export const load = "__swiptLoad";
export const dynamicImport = "__swiptImport";
export const replHead = `(async (${load}, ${dynamicImport}) => {let ${completion}; ${hoist}();`;
