# frozen_string_literal: true

require_relative "test_helper"

class AddBookOrchestratorTest < Test::Unit::TestCase
  def setup
    setup_memory_cache
    @http = fixture_http_client
    @db = { "authors" => [], "books" => [] }
  end

  def picker_for(overrides = {})
    defaults = {
      "Title" => "Crónicas Marcianas",
      "Subtitle" => "",
      "Original title" => "The Martian Chronicles",
      "First publishing year" => "1946",
      "Authors" => ["Ray Bradbury"],
      "Identifiers (ISBN-10 / ISBN-13)" => [{ "type" => "ISBN_13", "value" => "9788445078259" }],
      "Publisher" => "Minotauro",
      "Saga" => "",
      "Cover URL" => "",
      "Score" => 6,
      "ConfirmSave" => true
    }
    ScriptedPicker.new(defaults.merge(overrides))
  end

  def test_creates_book_with_resolved_authors
    outcome = add_book(db: @db, query: "9788445078259", http: @http,
                       picker: picker_for, save: false, download_covers: false)

    refute_nil outcome[:book]
    book = outcome[:book]

    assert_equal "Crónicas Marcianas", book["title"]
    assert_equal "The Martian Chronicles", book["original_title"]
    assert_equal 6, book["score"]
    assert_equal "Minotauro", book["publisher"]

    assert_equal 1, book["author_ids"].size, "single author resolved"
    assert_equal "Ray Bradbury", @db["authors"].first["name"]
    assert_equal book["author_ids"].first, @db["authors"].first["id"]
  end

  def test_returns_existing_when_title_already_in_db
    @db["books"] << { "id" => 1, "title" => "Crónicas Marcianas", "author_ids" => [] }
    outcome = add_book(db: @db, query: "9788445078259", http: @http,
                       picker: picker_for, save: false, download_covers: false)
    assert outcome[:existing]
    assert_equal "Crónicas Marcianas", outcome[:existing]["title"]
  end

  def test_user_decline_does_not_persist
    outcome = add_book(db: @db, query: "9788445078259", http: @http,
                       picker: picker_for("ConfirmSave" => false),
                       save: true, download_covers: false)
    refute outcome[:saved]
    assert_empty @db["books"]
  end

  def test_isbn_identifiers_normalized_on_string_input
    overrides = { "Identifiers (ISBN-10 / ISBN-13)" => ["978-84-450-7825-9"] }
    outcome = add_book(db: @db, query: "9788445078259", http: @http,
                       picker: picker_for(overrides), save: false, download_covers: false)
    ids = outcome[:book]["identifiers"]
    assert_equal "ISBN_13", ids.first["type"]
    assert_equal "9788445078259", ids.first["value"]
  end

  def test_saga_string_picks_up_order_from_picker
    picker = picker_for("Saga" => "Foundation", "SagaOrder" => 3)
    outcome = add_book(db: @db, query: "9788445078259", http: @http,
                       picker: picker, save: false, download_covers: false)
    assert_equal({ "name" => "Foundation", "order" => 3 }, outcome[:book]["saga"])
  end

  def test_author_fallback_used_when_picker_returns_empty
    picker = picker_for("Authors" => [], "AuthorFallback" => ["Manual Author"])
    outcome = add_book(db: @db, query: "9788445078259", http: @http,
                       picker: picker, save: false, download_covers: false)
    assert_equal "Manual Author", @db["authors"].first["name"]
    assert_equal 1, outcome[:book]["author_ids"].size
  end
end
