'use strict';

const express = require('express');
const path = require('path');
const fs = require('fs');
const { MongoClient, ObjectId } = require('mongodb');

const PORT = process.env.PORT || 3000;
const MONGODB_URI = process.env.MONGODB_URI;
const MONGODB_DB = process.env.MONGODB_DB || 'wizdemo';
const WIZ_FILE = path.join(__dirname, 'wizexercise.txt');

if (!MONGODB_URI) {
  console.error('MONGODB_URI is not set. Refusing to start.');
  process.exit(1);
}

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

let db = null;
let dbError = null;

async function connect() {
  const client = new MongoClient(MONGODB_URI, {
    serverSelectionTimeoutMS: 5000,
  });
  await client.connect();
  db = client.db(MONGODB_DB);
  await db.command({ ping: 1 });
  dbError = null;
  console.log(`Connected to MongoDB database "${MONGODB_DB}"`);
}

async function connectWithRetry(attempt = 1) {
  try {
    await connect();
  } catch (err) {
    dbError = err.message;
    const delay = Math.min(30000, 2000 * attempt);
    console.error(`MongoDB connection failed (attempt ${attempt}): ${err.message}`);
    setTimeout(() => connectWithRetry(attempt + 1), delay);
  }
}

function requireDb(req, res, next) {
  if (!db) {
    return res.status(503).json({ error: 'Database unavailable', detail: dbError });
  }
  next();
}

// --- Exercise validation endpoints -----------------------------------------

// Proof that wizexercise.txt is baked into the running container image.
app.get('/wizexercise.txt', (req, res) => {
  fs.readFile(WIZ_FILE, 'utf8', (err, data) => {
    if (err) return res.status(404).type('text/plain').send('wizexercise.txt not found');
    res.type('text/plain').send(data);
  });
});

app.get('/healthz', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/readyz', (req, res) => {
  if (!db) return res.status(503).json({ status: 'degraded', detail: dbError });
  res.json({ status: 'ready' });
});

app.get('/api/status', async (req, res) => {
  const status = {
    wizexerciseFile: fs.existsSync(WIZ_FILE),
    wizexerciseContents: fs.existsSync(WIZ_FILE)
      ? fs.readFileSync(WIZ_FILE, 'utf8').trim()
      : null,
    database: 'disconnected',
    databaseVersion: null,
    databaseHost: MONGODB_URI.replace(/\/\/[^@]*@/, '//<redacted>@'),
    pod: process.env.HOSTNAME || 'unknown',
  };

  if (db) {
    try {
      const info = await db.admin().serverStatus();
      status.database = 'connected';
      status.databaseVersion = info.version;
    } catch (err) {
      status.database = 'error';
      status.detail = err.message;
    }
  } else {
    status.detail = dbError;
  }

  res.json(status);
});

// --- Todo API ---------------------------------------------------------------

app.get('/api/todos', requireDb, async (req, res, next) => {
  try {
    const todos = await db.collection('todos').find({}).sort({ createdAt: -1 }).toArray();
    res.json(todos);
  } catch (err) {
    next(err);
  }
});

app.post('/api/todos', requireDb, async (req, res, next) => {
  try {
    const title = String(req.body.title || '').trim();
    if (!title) return res.status(400).json({ error: 'Add a task name before saving.' });

    const doc = { title: title.slice(0, 280), done: false, createdAt: new Date() };
    const result = await db.collection('todos').insertOne(doc);
    res.status(201).json({ ...doc, _id: result.insertedId });
  } catch (err) {
    next(err);
  }
});

app.patch('/api/todos/:id', requireDb, async (req, res, next) => {
  try {
    const result = await db.collection('todos').findOneAndUpdate(
      { _id: new ObjectId(req.params.id) },
      { $set: { done: Boolean(req.body.done) } },
      { returnDocument: 'after' }
    );
    if (!result) return res.status(404).json({ error: 'That task no longer exists.' });
    res.json(result.value || result);
  } catch (err) {
    next(err);
  }
});

app.delete('/api/todos/:id', requireDb, async (req, res, next) => {
  try {
    await db.collection('todos').deleteOne({ _id: new ObjectId(req.params.id) });
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'The request failed. Check the pod logs for details.' });
});

connectWithRetry();

app.listen(PORT, '0.0.0.0', () => {
  console.log(`wiz-todo listening on :${PORT}`);
});
