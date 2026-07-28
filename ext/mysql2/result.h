#ifndef MYSQL2_RESULT_H
#define MYSQL2_RESULT_H

void init_mysql2_result(void);
VALUE rb_mysql_result_to_obj(VALUE client, VALUE encoding, VALUE options, MYSQL_RES *r, VALUE statement);

/* Scalar field metadata captured while the MYSQL_RES is alive, so that
 * field_types (and friends) keep working after the result set is freed. */
typedef struct {
  unsigned long length;
  unsigned int charsetnr;
  unsigned int decimals;
  unsigned int flags;
  int type; /* enum enum_field_types */
  char is_json; /* MariaDB extended metadata, only resolvable while alive */
  /* Column encoding resolution, computed once per column instead of per cell.
   * 0 = unresolved, 1 = binary (no default_internal export), 2 = by index
   * (enc_index valid), 3 = connection encoding fallback. */
  char enc_state;
  int enc_index;
} mysql2_field_meta;

typedef struct {
  VALUE fields;
  VALUE fieldSymbols;
  VALUE fieldTypes;
  VALUE rows;
  VALUE client;
  VALUE encoding;
  VALUE statement;
  my_ulonglong numberOfFields;
  my_ulonglong numberOfRows;
  unsigned long lastRowProcessed;
  char is_streaming;
  char streamingComplete;
  char resultFreed;
  MYSQL_RES *result;
  mysql2_field_meta *field_meta;
  mysql_stmt_wrapper *stmt_wrapper;
  mysql_client_wrapper *client_wrapper;
  /* statement result bind buffers */
  MYSQL_BIND *result_buffers;
  my_bool *is_null;
  my_bool *error;
  unsigned long *length;
} mysql2_result_wrapper;

#endif
