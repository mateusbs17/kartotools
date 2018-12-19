# Tools for debugging kartotherian logs

# Get all errors
cat tilerator_main.log | jq -r '{msg: .msg, err: .err?} | select(.err != null)'

# Count unique errors errors
cat tilerator_main.log | jq -r '{msg: .msg, err: .err?, date: time} | select(.err != null)' | jq 'select(.err != null)' | jq -s . | jq "unique"

# Count unique errors errors
cat tilerator_main.log | jq -r '{msg: .msg, err: .err?} | select(.err != null)' | jq 'select(.err != null)' | jq -s . | jq "unique | length" 

# Get between dates
cat tilerator_main.log| jq '. | select (.time > "2018-08-11T00:00:00" and .time < "2018-09-11T23:59:59")'

cat tilerator_main.log | jq '. | select (.time > "2018-08-11T00:00:00")' | jq -r '{msg: .msg, err: .err?, date: time} | select(.err != null)' | jq 'select(.err != null)' | jq -s . | jq "unique"