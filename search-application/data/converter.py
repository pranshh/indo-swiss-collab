import pandas as pd

df = pd.read_parquet('publication_details.parquet', engine='pyarrow')
df.to_parquet('publication_details.parquet', compression='zstd')  # or 'snappy'


for col in df.columns:
    print(f"{col}")