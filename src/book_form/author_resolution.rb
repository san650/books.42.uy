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

# Replace each candidate's value with the canonical author name when the
# value matches an existing author's name or any of their aliases. The
# downstream build_options step then dedupes aliases that all point to the
# same canonical record.
def canonicalize_author_candidates(db, candidates)
  candidates.map do |c|
    match = find_author_by_name(db, c[:value])
    next c unless match
    next c if match["name"] == c[:value]

    c.merge(value: match["name"])
  end
end
