import pandas as pd
import anthropic
import time
import os

start_time = time.time()

df = pd.read_csv("institutions_for_cleaning_20250314.csv")

indian_df = pd.read_csv("Indian Institutes.csv")
indian_list = indian_df["University Name"].tolist()

swiss_df = pd.read_csv("Swiss Institutes.csv")
swiss_list = swiss_df["Research Institution"].tolist()

output_file = "institutions_standardized_output_swiss.csv"

client = anthropic.Anthropic(api_key="")

if os.path.exists(output_file):
    out_df = pd.read_csv(output_file)
else:
    out_df = df.copy()
    out_df["standardized name"] = ""

def standardizer(institute_name, country_list):
    prompt = f"""Extract and standardize the institute name from the following text:
    
    {institute_name}
    
    Use these reference examples to ensure naming consistency:
    {country_list}
    
    Instructions:
    1. Return exactly one standardized name that matches an entry in the list if possible.
    2. Use and maintain standard abbreviations.
    3. Include relevant location information (city/state) if available.
    4. If no match is found try your best to return a standardized output but include an exclamation mark at the end (!). 
    5. If no match is found, return '---'.
    6. Do not include any explanation or reasoning in your output.
    7. Maintian consistency among insitutes name please.
    """
    
    response = client.messages.create(
        model="claude-3-5-haiku-20241022",
        max_tokens=1024,
        messages=[
            {"role": "user", "content": prompt}
        ]
    )
    return response.content[0].text.strip()

for idx, row in out_df.iterrows():
    current_std_name = out_df.at[idx, "standardized name"]
    if pd.notnull(current_std_name) and current_std_name.strip() != "":
        continue

    institute_name = row["institution"]
    country = row["country"]
    print(f"Processing row {idx+1}...")
    print(institute_name)
    if country == "India":
        standardized_name = standardizer(institute_name, indian_list)
    else:
        standardized_name = standardizer(institute_name, swiss_list)
    print(standardized_name)
    print("---")
    
    out_df.at[idx, "standardized name"] = standardized_name
    out_df.to_csv(output_file, index=False)

end_time = time.time()
execution_time = end_time - start_time
print(f"\nExecution time: {execution_time:.2f} seconds")