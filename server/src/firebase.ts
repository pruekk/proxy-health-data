import { applicationDefault, cert, initializeApp } from 'firebase-admin/app'
import { getFirestore } from 'firebase-admin/firestore'
import { env } from './env'

// FIREBASE_SERVICE_ACCOUNT (inline JSON) wins; otherwise Application Default Credentials
// (GOOGLE_APPLICATION_CREDENTIALS, `gcloud auth application-default login`, or the Cloud Run service account).
const credential = process.env.FIREBASE_SERVICE_ACCOUNT
  ? cert(JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT))
  : applicationDefault()

const app = initializeApp({ credential, projectId: env.projectId })

export const db = getFirestore(app, env.databaseId)

// REST transport avoids gRPC native quirks under Bun.
db.settings({ ignoreUndefinedProperties: true, preferRest: true })
