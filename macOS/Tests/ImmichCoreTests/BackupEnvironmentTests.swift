import XCTest
@testable import ImmichCore

final class BackupEnvironmentTests: XCTestCase {
    func testParserAcceptsOrdinaryImmichValuesWithoutEvaluatingShellSyntax() throws {
        let values = try DotEnvParser.parse(contents: """
        # Normal deployment settings
        DB_DATABASE_NAME=immich
        DB_USERNAME = postgres
        QUOTED_VALUE="two words"
        LITERAL_COMMAND=$(touch /should-never-run)
        BACKTICK=`also-not-run`
        export UPLOAD_LOCATION='/Volumes/Photos Library'
        """)

        XCTAssertEqual(values["DB_DATABASE_NAME"], "immich")
        XCTAssertEqual(values["DB_USERNAME"], "postgres")
        XCTAssertEqual(values["QUOTED_VALUE"], "two words")
        XCTAssertEqual(values["LITERAL_COMMAND"], "$(touch /should-never-run)")
        XCTAssertEqual(values["BACKTICK"], "`also-not-run`")
        XCTAssertEqual(values["UPLOAD_LOCATION"], "/Volumes/Photos Library")
    }

    func testParserRejectsMalformedKeysAndUnclosedQuotedValues() {
        XCTAssertThrowsError(try DotEnvParser.parse(contents: "DB-PASSWORD=value")) { error in
            XCTAssertEqual(error as? DotEnvError, .malformedLine(line: 1))
        }
        XCTAssertThrowsError(try DotEnvParser.parse(contents: "DB_PASSWORD=\"unterminated")) { error in
            XCTAssertEqual(error as? DotEnvError, .malformedQuotedValue(line: 1))
        }
    }
}
