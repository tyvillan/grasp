import GRDB

/// The full database schema, applied via ordered, named migrations so the
/// schema can evolve safely as the app grows. Table/column names use
/// snake_case to match GRDB's default row-decoding convention.
enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "semester") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("slug", .text).notNull().unique()
                t.column("sortKey", .integer).notNull()
                t.column("startsOn", .datetime)
                t.column("endsOn", .datetime)
            }

            try db.create(table: "course") { t in
                t.column("id", .text).primaryKey()
                t.column("semesterId", .text).references("semester", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("code", .text)
                t.column("colorHex", .text)
                t.column("folderPath", .text)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "ix_course_folder", on: "course", columns: ["folderPath"], unique: true,
                condition: Column("folderPath") != nil
            )

            try db.create(table: "material") { t in
                t.column("id", .text).primaryKey()
                t.column("courseId", .text).notNull().references("course", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("kind", .text).notNull()
                // markdown | pdf | docx | pptx | ipynb | image
                t.column("contentHash", .text)
                t.column("title", .text).notNull()
                t.column("noteDate", .datetime)
                t.column("topic", .text)
                t.column("chapter", .text)
                t.column("extractionState", .text).notNull()
                // pending | ok | skippedAsset | skippedEmpty | noTextLayer | unsupported | failed
                t.column("isStudyWorthy", .boolean).notNull().defaults(to: true)
                t.column("importedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(index: "ix_material_path", on: "material", columns: ["relativePath"], unique: true)
            try db.create(index: "ix_material_hash", on: "material", columns: ["contentHash"])
            try db.create(index: "ix_material_course", on: "material", columns: ["courseId"])

            try db.create(table: "materialLink") { t in
                t.column("materialId", .text).notNull().references("material", onDelete: .cascade)
                t.column("linkedMaterialId", .text).notNull().references("material", onDelete: .cascade)
                t.column("kind", .text).notNull() // sidecarOf | embeds
                t.primaryKey(["materialId", "linkedMaterialId", "kind"])
            }

            try db.create(table: "noteText") { t in
                t.column("materialId", .text).primaryKey().references("material", onDelete: .cascade)
                t.column("raw", .text).notNull()
                t.column("reflowed", .text).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("hasMath", .boolean).notNull().defaults(to: false)
            }

            try db.create(virtualTable: "noteFTS", using: FTS5()) { t in
                t.synchronize(withTable: "noteText")
                t.column("reflowed")
                t.tokenizer = .porter(wrapping: .unicode61())
            }

            try db.create(table: "deck") { t in
                t.column("id", .text).primaryKey()
                t.column("courseId", .text).notNull().references("course", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("chapter", .text)
                t.column("origin", .text).notNull() // auto | manual
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(index: "ix_deck_course", on: "deck", columns: ["courseId"])

            try db.create(table: "card") { t in
                t.column("id", .text).primaryKey()
                t.column("materialId", .text).references("material", onDelete: .setNull)
                t.column("front", .text).notNull()
                t.column("back", .text).notNull()
                t.column("hasMath", .boolean).notNull().defaults(to: false)
                t.column("imagePath", .text)
                t.column("sourceLine", .integer)
                t.column("origin", .text).notNull() // parser | ollama | manual | aiGenerated
                t.column("status", .text).notNull() // draft | active | suspended
                // FSRS scheduler state, inline: the due-queue query runs on
                // every card flip, so it must never require a join.
                t.column("due", .datetime).notNull()
                t.column("stability", .double).notNull().defaults(to: 0)
                t.column("difficulty", .double).notNull().defaults(to: 0)
                t.column("elapsedDays", .double).notNull().defaults(to: 0)
                t.column("scheduledDays", .double).notNull().defaults(to: 0)
                t.column("reps", .integer).notNull().defaults(to: 0)
                t.column("lapses", .integer).notNull().defaults(to: 0)
                t.column("schedulerState", .integer).notNull().defaults(to: 0)
                // 0 new, 1 learning, 2 review, 3 relearning
                t.column("lastReview", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("deletedAt", .datetime)
            }
            try db.create(
                index: "ix_card_due", on: "card", columns: ["due"],
                condition: Column("deletedAt") == nil && Column("status") == "active"
            )
            try db.create(index: "ix_card_material", on: "card", columns: ["materialId"])

            try db.create(table: "deckCard") { t in
                t.column("deckId", .text).notNull().references("deck", onDelete: .cascade)
                t.column("cardId", .text).notNull().references("card", onDelete: .cascade)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deckId", "cardId"])
            }
            try db.create(index: "ix_deckcard_card", on: "deckCard", columns: ["cardId"])

            try db.create(table: "review") { t in
                t.column("id", .text).primaryKey()
                t.column("cardId", .text).notNull().references("card", onDelete: .cascade)
                t.column("reviewedAt", .datetime).notNull()
                t.column("grade", .integer).notNull() // 1 again .. 4 easy
                t.column("source", .text).notNull()   // flashcards | learn | test | cram | manual
                t.column("elapsedMS", .integer)
                t.column("dueBefore", .datetime)
                t.column("dueAfter", .datetime).notNull()
                t.column("stabilityAfter", .double)
                t.column("difficultyAfter", .double)
                t.column("schedulerVersion", .text).notNull()
            }
            try db.create(index: "ix_review_card", on: "review", columns: ["cardId", "reviewedAt"])
            try db.create(index: "ix_review_day", on: "review", columns: ["reviewedAt"])

            try db.create(table: "learnState") { t in
                t.column("cardId", .text).primaryKey().references("card", onDelete: .cascade)
                t.column("level", .integer).notNull().defaults(to: 0)
                t.column("consecutiveCorrect", .integer).notNull().defaults(to: 0)
                t.column("lastSeenAt", .datetime)
            }

            try db.create(table: "testAttempt") { t in
                t.column("id", .text).primaryKey()
                t.column("deckId", .text).references("deck", onDelete: .setNull)
                t.column("configJSON", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("scoreNumerator", .integer)
                t.column("scoreDenominator", .integer)
            }

            try db.create(table: "testItem") { t in
                t.column("id", .text).primaryKey()
                t.column("attemptId", .text).notNull().references("testAttempt", onDelete: .cascade)
                t.column("cardId", .text).references("card", onDelete: .setNull)
                t.column("ordinal", .integer).notNull()
                t.column("questionType", .text).notNull()
                t.column("promptText", .text).notNull()
                t.column("choicesJSON", .text)
                t.column("correctAnswer", .text)
                t.column("givenAnswer", .text)
                t.column("isCorrect", .boolean)
            }

            try db.create(table: "exam") { t in
                t.column("id", .text).primaryKey()
                t.column("courseId", .text).notNull().references("course", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("examDate", .datetime).notNull()
            }

            try db.create(table: "importRun") { t in
                t.column("id", .text).primaryKey()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("filesScanned", .integer)
                t.column("filesChanged", .integer)
                t.column("filesSkippedAsset", .integer)
                t.column("filesSkippedEmpty", .integer)
                t.column("cardsCreated", .integer)
                t.column("errorsJSON", .text)
            }
        }

        // A folder the scanner should never turn into a course, keyed by
        // its exact `Course.folderPath` string. Separate from `isArchived`
        // deliberately: archiving hides a course but still leaves its row
        // in place for `findOrCreateCourse` to find and reuse on rescan,
        // which is what makes it safe and reversible. This table is what
        // makes a *delete* safe too -- without an entry here, deleting a
        // vault-backed course's row just means the very next scan finds no
        // match and creates a brand new one.
        migrator.registerMigration("v2_excluded_folder") { db in
            try db.create(table: "excludedFolder") { t in
                t.column("folderPath", .text).primaryKey()
                t.column("excludedAt", .datetime).notNull()
            }
        }

        // Distinguishes an ephemeral, AI-generated test-only question
        // (cardId always nil by design) from a real card-backed testItem
        // whose card was later deleted (cardId set to nil by the existing
        // `onDelete: .setNull` FK) -- both look identical by cardId alone.
        migrator.registerMigration("v3_test_item_ai_generated") { db in
            try db.alter(table: "testItem") { t in
                t.add(column: "isAIGenerated", .boolean).notNull().defaults(to: false)
            }
        }

        // Backs the context-validation pipeline: `originalBack` preserves
        // the pre-refinement text so the review UI can show a diff and
        // offer a revert, `isContextRefined` flags which cards have one.
        migrator.registerMigration("v4_card_context_refinement") { db in
            try db.alter(table: "card") { t in
                t.add(column: "originalBack", .text)
                t.add(column: "isContextRefined", .boolean).notNull().defaults(to: false)
            }
        }

        // Widens the old exams-only table into the calendar's one table of
        // dated things (exams, quizzes, deadlines, study blocks). Built as
        // create-copy-drop rather than a rename plus `ALTER`s because two
        // of the changes SQLite can't do in place: `courseId` has to lose
        // its NOT NULL (a personal study block belongs to no course), and
        // the new `deckId` needs a real foreign key. Every existing exam
        // row carries over as `kind = 'exam'`, keeping whatever exam dates
        // are already set -- and the FSRS biasing they drive -- intact.
        migrator.registerMigration("v5_calendar_event") { db in
            try db.create(table: "calendarEvent") { t in
                t.column("id", .text).primaryKey()
                t.column("courseId", .text).references("course", onDelete: .cascade)
                t.column("deckId", .text).references("deck", onDelete: .setNull)
                t.column("kind", .text).notNull().defaults(to: "exam")
                t.column("title", .text).notNull()
                t.column("startsAt", .datetime).notNull()
                t.column("endsAt", .datetime)
                t.column("isAllDay", .boolean).notNull().defaults(to: true)
                t.column("sourceEventId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.execute(sql: """
                INSERT INTO calendarEvent
                    (id, courseId, deckId, kind, title, startsAt, endsAt, isAllDay,
                     sourceEventId, createdAt, updatedAt)
                SELECT id, courseId, NULL, 'exam', name, examDate, NULL, 1,
                       NULL, examDate, examDate
                FROM exam
                """)
            try db.drop(table: "exam")
            // Every calendar read is a date-range scan (a month grid, the
            // agenda's next N, Home's upcoming alerts), never a lookup by id.
            try db.create(index: "calendarEvent_on_startsAt", on: "calendarEvent", columns: ["startsAt"])
        }

        // Links a generated study block back to the exam it was planned
        // for. Without it, regenerating a plan (or deleting the exam)
        // would leave the old blocks stranded on the calendar with no way
        // to tell them apart from ones added by hand -- which must never
        // be swept up by a regenerate.
        migrator.registerMigration("v6_calendar_event_parent") { db in
            try db.alter(table: "calendarEvent") { t in
                t.add(column: "parentEventId", .text)
            }
        }

        return migrator
    }
}
