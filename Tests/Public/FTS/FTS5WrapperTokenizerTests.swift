import XCTest
import Foundation
#if USING_SQLCIPHER
    import GRDBCipher
#elseif USING_CUSTOMSQLITE
    import GRDBCustomSQLite
#else
    import GRDB
#endif

// A custom wrapper tokenizer that ignores some tokens
private final class StopWordsTokenizer : FTS5WrapperTokenizer {
    static let name = "stopWords"
    var wrappedTokenizer: FTS5Tokenizer
    let ignoredTokens: [String]
    
    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
        ignoredTokens = ["bar"]
    }
    
    func customizesWrappedTokenizer(flags: FTS5TokenizeFlags) -> Bool {
        return true
    }
    
    func accept(token: String, flags: FTS5TokenFlags, notify: FTS5TokenNotifier) throws {
        if !ignoredTokens.contains(token){
            try notify(token, flags)
        }
    }
}

// A custom wrapper tokenizer that converts tokens to NFKC so that "fi" can match "ﬁ" (U+FB01: LATIN SMALL LIGATURE FI)
private final class NFKCTokenizer : FTS5WrapperTokenizer {
    static let name = "nfkc"
    let wrappedTokenizer: FTS5Tokenizer
    
    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
    }
    
    func customizesWrappedTokenizer(flags: FTS5TokenizeFlags) -> Bool {
        return true
    }
    
    func accept(token: String, flags: FTS5TokenFlags, notify: FTS5TokenNotifier) throws {
        try notify(token.precomposedStringWithCompatibilityMapping, flags)
    }
}

// A custom wrapper tokenizer that defines synonyms
private final class SynonymsTokenizer : FTS5WrapperTokenizer {
    static let name = "synonyms"
    let wrappedTokenizer: FTS5Tokenizer
    let synonyms: [Set<String>]

    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
        synonyms = [["first", "1st"]]
    }
    
    func customizesWrappedTokenizer(flags: FTS5TokenizeFlags) -> Bool {
        // Don't look for synonyms when tokenizing queries, as advised by
        // https://www.sqlite.org/fts5.html#synonym_support
        return !flags.contains(.query)
    }
    
    func accept(token: String, flags: FTS5TokenFlags, notify: FTS5TokenNotifier) throws {
        if let synonyms = synonyms.first(where: { $0.contains(token) }) {
            for (index, synonym) in synonyms.enumerated() {
                let synonymFlags = (index == 0) ? flags : flags.union(.colocated)
                try notify(synonym, synonymFlags)
            }
        } else {
            try notify(token, flags)
        }
    }
}

class FTS5WrapperTokenizerTests: GRDBTestCase {
    
    func testStopWordsTokenizerDatabaseQueue() {
        assertNoError {
            let dbQueue = try makeDatabaseQueue()
            dbQueue.add(tokenizer: StopWordsTokenizer.self)
            
            try dbQueue.inDatabase { db in
                try db.create(virtualTable: "documents", using: FTS5()) { t in
                    // TODO: improve this API
                    t.tokenizer = StopWordsTokenizer.tokenizer()
                    t.column("content")
                }
                
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["foo bar"])
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["foo baz"])
                
                // foo is not ignored
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["foo"]), 2)
                // bar is ignored
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["bar"]), 0)
                // bar is ignored in queries too: the "foo bar baz" phrase matches the "foo baz" content
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"foo bar baz\""]), 1)
            }
        }
    }
    
    func testStopWordsTokenizerDatabasePool() {
        assertNoError {
            let dbPool = try makeDatabaseQueue()
            dbPool.add(tokenizer: StopWordsTokenizer.self)
            
            try dbPool.write { db in
                try db.create(virtualTable: "documents", using: FTS5()) { t in
                    t.tokenizer = StopWordsTokenizer.tokenizer(arguments: ["foo", "bar"])
                    t.column("content")
                }
                
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["foo bar"])
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["foo baz"])
                
                // foo is not ignored
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["foo"]), 2)
                // bar is ignored
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["bar"]), 0)
                // bar is ignored in queries too: the "foo bar baz" phrase matches the "foo baz" content
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"foo bar baz\""]), 1)
            }
            
            dbPool.read { db in
                // foo is not ignored
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["foo"]), 2)
                // bar is ignored
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["bar"]), 0)
                // bar is ignored in queries too: the "foo bar baz" phrase matches the "foo baz" content
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"foo bar baz\""]), 1)
            }
        }
    }
    
    func testNFKCTokenizer() {
        assertNoError {
            let dbQueue = try makeDatabaseQueue()
            dbQueue.add(tokenizer: NFKCTokenizer.self)
            
            // Without NFKC conversion
            try dbQueue.inDatabase { db in
                try db.create(virtualTable: "documents", using: FTS5()) { t in
                    t.tokenizer = .unicode61()
                    t.column("content")
                }
                
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["aimé\u{FB01}"]) // U+FB01: LATIN SMALL LIGATURE FI
                
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["aimé\u{FB01}"]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["aimefi"]), 0)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["aim\u{00E9}fi"]), 0)
            }
            
            // With NFKC conversion
            try dbQueue.inDatabase { db in
                try db.create(virtualTable: "nkfcDocuments", using: FTS5()) { t in
                    t.tokenizer = NFKCTokenizer.tokenizer()
                    t.column("content")
                }
                
                try db.execute("INSERT INTO nkfcDocuments VALUES (?)", arguments: ["aimé\u{FB01}"]) // U+FB01: LATIN SMALL LIGATURE FI
                
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM nkfcDocuments WHERE nkfcDocuments MATCH ?", arguments: ["aimé\u{FB01}"]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM nkfcDocuments WHERE nkfcDocuments MATCH ?", arguments: ["aimefi"]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM nkfcDocuments WHERE nkfcDocuments MATCH ?", arguments: ["aim\u{00E9}fi"]), 1)
            }
        }
    }
    
    func testSynonymTokenizer() {
        assertNoError {
            let dbQueue = try makeDatabaseQueue()
            dbQueue.add(tokenizer: SynonymsTokenizer.self)
            
            try dbQueue.inDatabase { db in
                try db.create(virtualTable: "documents", using: FTS5()) { t in
                    t.tokenizer = SynonymsTokenizer.tokenizer()
                    t.column("content")
                }
                
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["first foo"])
                try db.execute("INSERT INTO documents VALUES (?)", arguments: ["1st bar"])
                
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["first"]), 2)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["1st"]), 2)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"first foo\""]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"1st foo\""]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"first bar\""]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["\"1st bar\""]), 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["fi*"]), 2)
                XCTAssertEqual(Int.fetchOne(db, "SELECT COUNT(*) FROM documents WHERE documents MATCH ?", arguments: ["1s*"]), 2)
            }
        }
    }
}