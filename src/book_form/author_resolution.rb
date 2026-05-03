# frozen_string_literal: true

require_relative "../authors"

def resolve_author_ids(db, author_names)
  author_names.map do |name|
    existing = find_author_by_name(db, name)
    if existing
      warn "  [MATCH] #{name} -> existing author ##{existing["id"]}"
      existing
    else
      author = find_or_create_author(db, name, aliases: [])
      warn "  [NEW]   #{name} -> author ##{author["id"]}"
      author
    end
  end.map { |a| a["id"] }
end
