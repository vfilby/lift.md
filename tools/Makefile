.PHONY: test validate generate install

install:
	pip install -r requirements.txt

test:
	python -m pytest -v

validate:
	@if [ -z "$(FILE)" ]; then echo "Usage: make validate FILE=path/to/file.json"; exit 1; fi
	python validate_export.py $(FILE)

generate:
	python generate_export.py $(ARGS)
