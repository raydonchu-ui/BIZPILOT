import * as core from './app/core';
import * as ops from './app/ops';
import * as intel from './app/intel';

export const en = { ...core.en, ...ops.en, ...intel.en };
export const fr: typeof en = { ...core.fr, ...ops.fr, ...intel.fr };
