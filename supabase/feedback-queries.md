# Reading feedback

Open **SQL Editor**, choose **New query**, paste one of these, and **Save** it with the name in bold. They read the `feedback_inbox` view, so they work as they are. To change a row's `status`, use the **Table Editor**: open `feedback`, click the `status` cell and pick `seen` or `done`.

## **New feedback**

```sql
select created_at, type, rating, message, from_name, email, screen, platform, app_version, screenshot_path
from public.feedback_inbox
where status = 'new'
order by created_at desc;
```

## **Feedback by type**

How much of each kind, and the average rating, over the last 30 days.

```sql
select type, count(*) as how_many, round(avg(rating), 1) as avg_rating
from public.feedback_inbox
where created_at > now() - interval '30 days'
group by type
order by how_many desc;
```

## **Feedback by app version**

```sql
select app_version, build, platform, count(*) as how_many,
       count(*) filter (where type = 'bug') as bugs,
       round(avg(rating), 1) as avg_rating,
       max(created_at) as latest
from public.feedback_inbox
group by app_version, build, platform
order by latest desc;
```

## Seeing a screenshot

A row with a `screenshot_path` has a picture in **Storage -> feedback-screenshots** with that file name. The bucket is private, so you open it there while signed in to the dashboard.
