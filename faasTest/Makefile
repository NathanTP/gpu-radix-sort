HANDLER_DIR=$(abspath ./handler/)

all: handler install

handler: f.py ../libsort/libsort.so
	mkdir -p ${HANDLER_DIR}
	cp f.py ${HANDLER_DIR}/
	cp ../libsort/libsort.so ${HANDLER_DIR}/
	cp -r pylibsort ${HANDLER_DIR}/

install: handler
	srk function remove --function-name radixsort
	srk function create --source ${HANDLER_DIR} --function-name radixsort

clean:
	rm -rf handler

print-%  : ; @echo $* = $($*)
