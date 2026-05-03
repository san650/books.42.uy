# frozen_string_literal: true

require_relative "test_helper"

class EditBookOrchestratorTest < Test::Unit::TestCase
  def setup
    setup_memory_cache
    @http = fixture_http_client
    @db = {
      "authors" => [{ "id" => 1, "name" => "Ray Bradbury", "aliases" => [] }],
      "books" => [{
        "id" => 1,
        "title" => "Crónicas Marcianas",
        "subtitle" => "",
        "original_title" => "",
        "first_publishing_date" => "",
        "author_ids" => [1],
        "identifiers" => [{ "type" => "ISBN_13", "value" => "9788445078259" }],
        "covers" => [],
        "publisher" => "",
        "saga" => nil,
        "score" => 5,
        "review" => ""
      }]
    }
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
      "Score" => nil,
      "ConfirmSave" => true
    }
    ScriptedPicker.new(defaults.merge(overrides))
  end

  def test_updates_existing_book_in_place
    book = @db["books"].first
    outcome = edit_book(db: @db, book: book, http: @http,
                       picker: picker_for, save: false)

    refute outcome[:saved]
    assert_equal "The Martian Chronicles", book["original_title"]
    assert_equal "1946", book["first_publishing_date"]
    assert_equal "Minotauro", book["publisher"]
    assert_equal 5, book["score"], "score preserved when picker.score_update returns nil"
  end

  def test_score_update_is_applied
    book = @db["books"].first
    edit_book(db: @db, book: book, http: @http,
              picker: picker_for("Score" => 9), save: false)
    assert_equal 9, book["score"]
  end

  def test_existing_author_is_reused
    book = @db["books"].first
    edit_book(db: @db, book: book, http: @http,
              picker: picker_for, save: false)
    assert_equal 1, @db["authors"].size, "no duplicate author created"
    assert_equal [1], book["author_ids"]
  end

  def test_new_author_creates_entry
    book = @db["books"].first
    edit_book(db: @db, book: book, http: @http,
              picker: picker_for("Authors" => ["Ray Bradbury", "New Co-author"]), save: false)
    assert_equal 2, @db["authors"].size
    assert book["author_ids"].size == 2
  end

  def test_decline_to_save_returns_unsaved
    book = @db["books"].first
    outcome = edit_book(db: @db, book: book, http: @http,
                       picker: picker_for("ConfirmSave" => false), save: true)
    refute outcome[:saved]
  end
end
