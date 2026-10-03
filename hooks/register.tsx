import type { Register } from 'claude-code'

import { register as report } from './report/register'
import { register as seats } from './seats/register'

/** A plugin loads one hooks module, so the seat pane and the findings board register through this one. */
export const register: Register = on => {
  seats(on)
  report(on)
}
