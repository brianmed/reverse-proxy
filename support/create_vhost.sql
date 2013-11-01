BEGIN;
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
      NEW.updated = now(); 
      RETURN NEW;
END;
$$ language 'plpgsql';
COMMIT;

CREATE TABLE vhost(
  id serial not null PRIMARY KEY,
  header VARCHAR(128) NOT NULL,
  config VARCHAR(128) NOT NULL,
  updated timestamp default CURRENT_TIMESTAMP,
  inserted timestamp default CURRENT_TIMESTAMP,
  UNIQUE(header, config)
);

CREATE TRIGGER user_timestamp BEFORE INSERT OR UPDATE ON vhost
FOR EACH ROW EXECUTE PROCEDURE update_timestamp();

GRANT SELECT ON TABLE vhost TO kevin;
GRANT INSERT ON TABLE vhost TO kevin;
GRANT UPDATE ON TABLE vhost TO kevin;
GRANT DELETE ON TABLE vhost TO kevin;

GRANT USAGE, SELECT ON SEQUENCE vhost_id_seq TO kevin;
COMMIT;
