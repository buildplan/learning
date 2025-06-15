**A crontab entry has five time-and-date fields, followed by the command to be run.**

```bash
 ┌───────────── minute (0 - 59)
 │ ┌───────────── hour (0 - 23)
 │ │ ┌───────────── day of the month (1 - 31)
 │ │ │ ┌───────────── month (1 - 12)
 │ │ │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday;
 │ │ │ │ │                                   7 is also Sunday on some systems)
 │ │ │ │ │
 │ │ │ │ │
 * * * * * command_to_execute
```

* * *

### Run at an Interval

The most common method is to use a step value with a slash (`/`). This tells cron to run the command at a specific interval.

- To run every 15 minutes:
    
    This will execute the command at :00, :15, :30, and :45 of every hour.
    
    `*/15 * * * * command_to_execute`
    
- To run every 30 minutes:
    
    This will execute at :00 and :30 of every hour.
    
	`*/30 * * * * command_to_execute`
    
- To run every 2 hours:
    
    This executes at 12 AM, 2 AM, 4 AM, and so on. The 0 in the minute field ensures it runs on the hour.
    
    `0 */2 * * * command_to_execute`
    

* * *

### Run at Specific Times

You can use a comma (`,`) to list multiple specific values for a field.

- To run at 8 AM, 12 PM, and 4 PM:
    
    This will execute the command at 8:00, 12:00, and 16:00.
	
	`0 8,12,16 * * * command_to_execute`
    
- **To run at 5 minutes and 35 minutes past every hour:**
    
    `5,35 * * * * command_to_execute`
    

* * *

### Run During a Specific Time Range

You can use a hyphen (`-`) to specify a range of hours or minutes. This is often combined with the interval syntax.

- **To run every 10 minutes, but only between 9 AM and 5 PM (17:00):**
    
    `*/10 9-17 * * * command_to_execute`
    
- **To run every hour from 6 AM to 6 PM (18:00):**
    
    `0 6-18 * * * command_to_execute`
