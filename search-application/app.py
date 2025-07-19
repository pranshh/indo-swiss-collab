from flask import Flask, render_template, request, Response
import pandas as pd
import re
import os

app = Flask(__name__)
DATA_PATH = os.path.join("data", "publications_full_dataset_2000-2024.parquet")
INST_PATH = os.path.join("data", "institutional_relationships_IN_CH.parquet")
AUTH_PATH = os.path.join("data", "authors_summary_in_ch.parquet")

RESULTS_PER_PAGE = 100

df_publications = pd.read_parquet(DATA_PATH)
df_institutions = pd.read_parquet(INST_PATH)['institution_name'] \
                    .dropna() \
                    .unique() \
                    .tolist()
df_institutions = sorted(df_institutions)
df_authors = pd.read_parquet(AUTH_PATH)['name']\
                    .dropna() \
                    .unique() \
                    .tolist()

print("AUTHORS column sample:", df_publications['authors'].head(3), 
      "\nType of first cell:", type(df_publications['authors'].iloc[0]))


def filter_dataframe(params):
    df = df_publications.copy()

    if params.get('title_abstract'):
        search_term = params['title_abstract']
        df = df[
            (df['title'].str.contains(search_term, case=False, na=False)) |
            (df['abstract'].str.contains(search_term, case=False, na=False))
        ]
    
    authors = params.get('authors', [])
    if authors:
        def author_match(cell):
            if not isinstance(cell, str): return False
            parts = [p.strip() for p in cell.split(';') if p.strip()]
            # for *each* user-entered author, at least one part must contain it
            return all(
                any(author.lower() in part.lower() for part in parts)
                for author in authors
            )
        df = df[df['authors'].apply(author_match)]

    print("AFTER AUTHOR FILTER: ", len(df), "rows")
    
    affils = params.get('affiliations', [])
    if affils:
        def inst_match(cell):
            if not isinstance(cell, str): return False
            parts = [p.strip() for p in cell.split(';') if p.strip()]
            return all(
                any(inst.lower() in part.lower() for part in parts)
                for inst in affils
            )
        df = df[df['institutions'].apply(inst_match)]

    if params.get('abstract'):
        df = df[df['abstract'].str.contains(params['abstract'], case=False, na=False)]

    if params.get('year'):
        year_val = params['year']
        if 'BETWEEN' in year_val:
            parts = year_val.replace('BETWEEN', '').split('AND')
            if len(parts) == 2:
                start, end = int(parts[0]), int(parts[1])
                df = df[(df['publication_year'] >= start) & (df['publication_year'] <= end)]
        elif year_val.startswith('>='):
            df = df[df['publication_year'] >= int(year_val[2:].strip())]
        elif year_val.startswith('<='):
            df = df[df['publication_year'] <= int(year_val[2:].strip())]
        else:
            try:
                df = df[df['publication_year'] == int(year_val)]
            except ValueError:
                pass

        print("After authors filter →", len(df), "rows")
        print("After insts filter   →", len(df), "rows")
        
    return df

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/institutions')
def get_institutions():
    return {'institutions': df_institutions}

@app.route('/authors')
def get_authors():
    return {'authors': df_authors}

@app.route('/search', methods=['POST'])
def search():
    try:
        page = int(request.form.get('page', 1))
        params = {
            # strings:
            'title':        request.form.get('title','').strip(),
            'abstract':     request.form.get('abstract','').strip(),
            'doi':          request.form.get('doi','').strip(),
            'year':         '',
            # lists:
            'authors':      [a.strip() for a in request.form.getlist('authors') if a.strip()],
            'affiliations': [i.strip() for i in request.form.getlist('affiliations') if i.strip()],
        }
        print("FILTER PARAMS:", params)

        year_from = request.form.get('year_from', '').strip()
        year_to = request.form.get('year_to', '').strip()
        if year_from and year_to:
            params['year'] = f"BETWEEN {year_from} AND {year_to}"
        elif year_from:
            params['year'] = f">= {year_from}"
        elif year_to:
            params['year'] = f"<= {year_to}"

        df = filter_dataframe(params)
        total_count = len(df)
        total_pages = (total_count + RESULTS_PER_PAGE - 1) // RESULTS_PER_PAGE
        start = (page - 1) * RESULTS_PER_PAGE
        end = start + RESULTS_PER_PAGE
        results_data = df.iloc[start:end].to_dict(orient='records')
        start_index = start + 1 if total_count > 0 else 0
        end_index = min(end, total_count)

        if df.empty:
            return render_template('results.html',
                                query="Advanced Search",
                                results=[],
                                total_count=0,
                                current_page=page,
                                total_pages=0,
                                message="No results found.",
                                search_type="advanced")

        return render_template('results.html',
                            query="Advanced Search",
                            results=results_data,
                            total_count=total_count,
                            current_page=page,
                            total_pages=total_pages,
                            start_index=start_index,
                            end_index=end_index,
                            search_type="advanced")

    except Exception as e:
        return render_template('results.html',
                            query="Advanced Search",
                            results=[],
                            error=str(e),
                            search_type="advanced")
    
@app.route('/download', methods=['POST'])
def download():
    params = {
        'title':        request.form.get('title','').strip(),
        'abstract':     request.form.get('abstract','').strip(),
        'doi':          request.form.get('doi','').strip(),
        'year':         '',
        'authors':      [a.strip() for a in request.form.getlist('authors') if a.strip()],
        'affiliations': [i.strip() for i in request.form.getlist('affiliations') if i.strip()],
    }

    year_from = request.form.get('year_from', '').strip()
    year_to   = request.form.get('year_to',   '').strip()
    if year_from and year_to:
        params['year'] = f"BETWEEN {year_from} AND {year_to}"
    elif year_from:
        params['year'] = f">= {year_from}"
    elif year_to:
        params['year'] = f"<= {year_to}"

    df = filter_dataframe(params)

    print("DOWNLOAD: total rows =", len(df))

    csv_data = df.to_csv(index=False)
    timestamp = pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')
    return Response(
        csv_data,
        mimetype="text/csv",
        headers={
            "Content-Disposition": f"attachment; filename=results_{timestamp}.csv"
        }
    )


@app.route('/about')
def about():
    return render_template('about.html')

if __name__ == '__main__':
    app.run()
