.PHONY: server add edit review format

server:
	python3 -m http.server 8000 -d docs

add:
	ruby scripts/add_book.rb $(filter-out $@,$(MAKECMDGOALS))

edit:
	ruby scripts/edit_book.rb

review:
	ruby scripts/add_review.rb

format:
	ruby scripts/precommit.rb

%:
	@:
