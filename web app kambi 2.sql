generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id             String   @id @default(cuid())
  email          String   @unique
  passwordHash   String
  role           UserRole @default(STUDENT)
  name           String
  createdAt      DateTime @default(now())
  updatedAt      DateTime @updatedAt
  student        Student? @relation(fields: [studentId], references: [id])
  studentId      String? 
}

model Student {
  id              String   @id @default(cuid())
  admissionNo     String   @unique
  user            User     @relation(fields: [userId], references: [id])
  userId          String   @unique
  dob             DateTime?
  classId         String?
  profilePhotoUrl String?
  createdAt       DateTime @default(now())
  updatedAt       DateTime @updatedAt
  assignments     Submission[]
}

model Assignment {
  id          String      @id @default(cuid())
  title       String
  description String?
  dueDate     DateTime?
  createdById String
  createdAt   DateTime    @default(now())
  updatedAt   DateTime    @updatedAt
  submissions Submission[]
}

model Submission {
  id            String   @id @default(cuid())
  assignment    Assignment @relation(fields: [assignmentId], references: [id])
  assignmentId  String
  student       Student    @relation(fields: [studentId], references: [id])
  studentId     String
  fileUrl       String
  filename      String
  mimeType      String
  size          Int
  submittedAt   DateTime @default(now())
  grade         String?
  feedback      String?
}

model Class {
  id           String   @id @default(cuid())
  title        String
  description  String?
  startAt      DateTime?
  durationMins Int?
  streamingUrl String?  // e.g., YouTube / Zoom / Jitsi link
  createdById  String
  createdAt    DateTime @default(now())
  updatedAt    DateTime @updatedAt
  links        Link[]
}

model Link {
  id        String   @id @default(cuid())
  title     String
  url       String
  type      LinkType
  class     Class?   @relation(fields: [classId], references: [id])
  classId   String?
  createdBy String
  createdAt DateTime @default(now())
}

model Podcast {
  id          String   @id @default(cuid())
  title       String
  description String?
  audioUrl    String
  durationSec Int?
  createdBy   String
  createdAt   DateTime @default(now())
  updatedAt   DateTime @updatedAt
}

enum UserRole {
  STUDENT
  ADMIN
  TEACHER
}

enum LinkType {
  RESOURCE
  READING
  CLASS_MATERIAL
  EXTERNAL
}

CREATE TABLE users (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'STUDENT',
  name TEXT NOT NULL,
  student_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE students (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_no TEXT UNIQUE NOT NULL,
  user_id TEXT UNIQUE NOT NULL,
  dob DATE,
  class_id TEXT,
  profile_photo_url TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE assignments (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT,
  due_date TIMESTAMP,
  created_by_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE submissions (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id TEXT REFERENCES assignments(id),
  student_id TEXT REFERENCES students(id),
  file_url TEXT NOT NULL,
  filename TEXT,
  mime_type TEXT,
  size INT,
  submitted_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  grade TEXT,
  feedback TEXT
);

CREATE TABLE classes (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT,
  start_at TIMESTAMP,
  duration_mins INT,
  streaming_url TEXT,
  created_by_id TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE links (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  type TEXT NOT NULL,
  class_id TEXT REFERENCES classes(id),
  created_by TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

CREATE TABLE podcasts (
  id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  description TEXT,
  audio_url TEXT NOT NULL,
  duration_sec INT,
  created_by TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

// utils/admission.ts
import { PrismaClient } from "@prisma/client";
const prisma = new PrismaClient();

export async function generateAdmissionNumber() {
  const year = new Date().getFullYear();
  // track sequences in a table or derive from count with lock.
  // simplest: use a dedicated table admission_sequences(year, last)
  const seq = await prisma.$transaction(async (tx) => {
    const rec = await tx.admissionSequence.findUnique({ where: { year } });
    if (rec) {
      const newLast = rec.last + 1;
      await tx.admissionSequence.update({ where: { year }, data: { last: newLast }});
      return newLast;
    } else {
      await tx.admissionSequence.create({ data: { year, last: 1 }});
      return 1;
    }
  });
  return `KAMBI-${year}-${String(seq).padStart(5, "0")}`;
}

model AdmissionSequence {
  year Int @id
  last Int @default(0)
}

// src/middleware/auth.ts
import jwt from "jsonwebtoken";
import { Request, Response, NextFunction } from "express";

export function authRequired(req: Request, res: Response, next: NextFunction) {
  const auth = req.headers.authorization;
  if (!auth) return res.status(401).json({ error: "Unauthorized" });
  const token = auth.split(" ")[1];
  try {
    const payload = jwt.verify(token, process.env.JWT_ACCESS_SECRET!);
    (req as any).user = payload;
    next();
  } catch {
    return res.status(401).json({ error: "Invalid token" });
  }
}

// src/routes/uploads.ts
import express from "express";
import AWS from "aws-sdk";
const s3 = new AWS.S3({ region: process.env.AWS_REGION });

const router = express.Router();

router.post("/presign", async (req, res) => {
  const { filename, contentType } = req.body;
  const key = `assignments/${Date.now()}-${filename}`;
  const params = {
    Bucket: process.env.S3_BUCKET!,
    Key: key,
    Expires: 60, // seconds to upload
    ContentType: contentType,
    ACL: "private"
  };

  const signedUrl = await s3.getSignedUrlPromise("putObject", params);
  res.json({ uploadUrl: signedUrl, key });
});

router.post("/submissions", authRequired, async (req, res) => {
  const { assignmentId, key, filename, mimeType, size } = req.body;
  // optionally generate public signed GET URL for playback
  const fileUrl = `https://${process.env.S3_BUCKET}.s3.amazonaws.com/${key}`;
  const sub = await prisma.submission.create({
    data: {
      assignmentId,
      studentId: (req as any).user.studentId,
      fileUrl,
      filename,
      mimeType,
      size: parseInt(size, 10)
    }
  });
  return res.status(201).json(sub);
});

// components/LiveClassEmbed.jsx
export default function LiveClassEmbed({ streamingUrl }) {
  if (!streamingUrl) return <p>No live stream scheduled.</p>;
  // if youtube link, embed; otherwise show join link
  if (streamingUrl.includes("youtube.com") || streamingUrl.includes("youtu.be")) {
    const embedUrl = streamingUrl.includes("watch") ? streamingUrl.replace("watch?v=", "embed/") : streamingUrl;
    return <iframe width="100%" height="480" src={embedUrl} allowFullScreen />;
  }
  return (
    <div>
      <a href={streamingUrl} target="_blank" rel="noopener noreferrer" className="btn">Join Live Class</a>
    </div>
  );
}

export default function PodcastCard({ podcast }) {
  return (
    <div className="p-4 shadow rounded">
      <h3 className="text-lg font-semibold">{podcast.title}</h3>
      <p className="text-sm">{podcast.description}</p>
      <audio controls src={podcast.audioUrl} style={{ width: "100%" }} />
    </div>
  );
}

// components/Layout.jsx
export default function Layout({ children }) {
  return (
    <div className="min-h-screen flex bg-gray-50">
      <aside className="w-64 bg-white p-4 border-r">
        <div className="text-2xl font-bold mb-6">Kambi Academy</div>
        <nav className="space-y-2">
          <a className="block p-2 rounded hover:bg-gray-100">Dashboard</a>
          <a className="block p-2 rounded hover:bg-gray-100">Students</a>
          <a className="block p-2 rounded hover:bg-gray-100">Assignments</a>
          <a className="block p-2 rounded hover:bg-gray-100">Live Classes</a>
        </nav>
      </aside>
      <main className="flex-1 p-6">{children}</main>
    </div>
  );
}

// tests/admission.test.ts
import { generateAdmissionNumber } from "../src/utils/admission";
test("generates admission number pattern", async () => {
  const adm = await generateAdmissionNumber();
  expect(adm).toMatch(/^KAMBI-\d{4}-\d{5}$/);
});

version: '3.8'
services:
  db:
    image: postgres:15
    environment:
      POSTGRES_PASSWORD: example
      POSTGRES_USER: kambi
      POSTGRES_DB: kambi_db
    volumes:
      - db_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
  api:
    build: ./api
    environment:
      DATABASE_URL: postgres://kambi:example@db:5432/kambi_db
      AWS_REGION: ...
    depends_on:
      - db
    ports:
      - "4000:4000"
  frontend:
    build: ./web
    ports:
      - "3000:3000"
volumes:
  db_data:

FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build
EXPOSE 4000
CMD ["node", "dist/index.js"]

kambi-academy/
├─ api/
│  ├─ src/
│  │  ├─ index.ts
│  │  ├─ routes/
│  │  │  ├─ auth.ts
│  │  │  ├─ assignments.ts
│  │  │  ├─ classes.ts
│  │  ├─ middleware/
│  │  ├─ utils/
│  ├─ prisma/
│  │  ├─ schema.prisma
│  ├─ package.json
├─ web/
│  ├─ pages/
│  ├─ components/
│  ├─ styles/
│  ├─ package.json
├─ docker-compose.yml

{
  "name": "kambi-api",
  "version": "1.0.0",
  "scripts": {
    "dev": "ts-node-dev --respawn src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "prisma:migrate": "prisma migrate dev"
  },
  "dependencies": {
    "@prisma/client": "^5.0.0",
    "bcrypt": "^5.1.0",
    "express": "^4.18.2",
    "jsonwebtoken": "^9.0.0",
    "aws-sdk": "^2.0.0"
  },
  "devDependencies": {
    "prisma": "^5.0.0",
    "ts-node-dev": "^2.0.0",
    "typescript": "^5.0.0"
  }
}

import express from "express";
import cors from "cors";
import authRoutes from "./routes/auth";
import uploadRoutes from "./routes/uploads";

const app = express();
app.use(cors({ origin: process.env.FRONTEND_URL, credentials: true }));
app.use(express.json());

app.use("/api/auth", authRoutes);
app.use("/api/uploads", uploadRoutes);

app.get("/", (req, res) => res.json({ ok: true }));
app.listen(process.env.PORT || 4000, () => console.log("Listening"));

DATABASE_URL=postgresql://kambi:example@localhost:5432/kambi_db
JWT_ACCESS_SECRET=very-secure-secret
JWT_REFRESH_SECRET=another-secret
AWS_REGION=...
S3_BUCKET=your-bucket
FRONTEND_URL=http://localhost:3000

cd /d "c:\Users\Emmanuel Mbukpa\Desktop\kambi web"
npx http-server -p 3000

