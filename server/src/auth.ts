import { Elysia } from 'elysia'
import { timingSafeEqual } from 'node:crypto'
import { env } from './env'

function resolveUser(token: string): string | null {
  if (!token) return null
  const given = Buffer.from(token)
  for (const [known, uid] of env.tokens) {
    const expected = Buffer.from(known)
    if (expected.length === given.length && timingSafeEqual(expected, given)) return uid
  }
  return null
}

// Bearer-token auth. Adds `uid` to the context of every route registered after `.use(auth)`.
export const auth = new Elysia({ name: 'auth' })
  .resolve({ as: 'scoped' }, ({ headers }) => {
    const header = headers.authorization ?? ''
    const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : ''
    return { uid: resolveUser(token) ?? '' }
  })
  .onBeforeHandle({ as: 'scoped' }, ({ uid, set }) => {
    if (!uid) {
      set.status = 401
      set.headers['www-authenticate'] = 'Bearer'
      return { error: 'unauthorized' }
    }
  })
