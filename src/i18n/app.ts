import * as core from './app/core';
import * as ops from './app/ops';
import * as intel from './app/intel';
import * as catalog from './app/catalog';
import * as market from './app/market';
import * as premium from './app/premium';

export const en = { ...core.en, ...ops.en, ...intel.en, ...catalog.en, ...market.en, ...premium.en };
export const fr: typeof en = { ...core.fr, ...ops.fr, ...intel.fr, ...catalog.fr, ...market.fr, ...premium.fr };
