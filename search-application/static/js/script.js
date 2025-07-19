// --- Index Page Script ---
document.addEventListener('DOMContentLoaded', function () {
    // Generic autocomplete setup function
    function setupAutocomplete(inputSelector, endpoint, datalistId) {
        const input = document.querySelector(inputSelector);
        if (input) {
            let datalist = document.getElementById(datalistId);
            if (!datalist) {
                datalist = document.createElement('datalist');
                datalist.id = datalistId;
                document.body.appendChild(datalist);
            }
            input.setAttribute('list', datalistId);

            fetch(endpoint)
                .then(res => res.json())
                .then(data => {
                    const fragment = document.createDocumentFragment();
                    const items = endpoint.includes('authors') ? data.authors : data.institutions;
                    items.forEach(item => {
                        const option = document.createElement('option');
                        option.value = item;
                        fragment.appendChild(option);
                    });
                    datalist.appendChild(fragment);
                });
        }
    }

    // Setup autocomplete for both institutions and authors
    setupAutocomplete('input[name="affiliations"]', '/institutions', 'institutionList');
    setupAutocomplete('input[name="authors"]', '/authors', 'authorsList');

    // Main search bar enhancements
    const mainSearch = document.getElementById('mainSearch');
    const form = document.querySelector('form');
    if (mainSearch && form) {
        mainSearch.addEventListener('keypress', function (e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                form.submit();
            }
        });
        mainSearch.addEventListener('focus', function () {
            this.parentElement.style.boxShadow = '0 12px 35px rgba(180, 82, 82, 0.2)';
        });
        mainSearch.addEventListener('blur', function () {
            this.parentElement.style.boxShadow = '0 8px 25px rgba(0, 0, 0, 0.1)';
        });
    }
    
    // --- Dynamic multi-input support ---
    function attachAddButtonListener(btn) {
        btn.addEventListener('click', () => {
            const container = document.getElementById(btn.dataset.target);
            const lastInput = container.querySelector('.multi-input:last-of-type');
            const clone = lastInput.cloneNode(true);
            
            // Reset the cloned input
            const input = clone.querySelector('input');
            input.value = '';
            
            // Preserve the datalist attribute if it exists
            const originalList = lastInput.querySelector('input').getAttribute('list');
            if (originalList) {
                input.setAttribute('list', originalList);
            }
            
            // Get and setup the new add button
            const newAddBtn = clone.querySelector('.add-btn');
            attachAddButtonListener(newAddBtn);
            
            container.appendChild(clone);
        });
    }

    // Attach listeners to initial buttons
    document.querySelectorAll('.add-btn').forEach(btn => {
        attachAddButtonListener(btn);
    });

    // --- About Page Enhancements ---
    // Animate content on scroll
    const animatedElements = document.querySelectorAll('.content-container > *');
    if (animatedElements.length) {
        const observer = new IntersectionObserver(function (entries) {
            entries.forEach(entry => {
                if (entry.isIntersecting) {
                    entry.target.style.opacity = '1';
                    entry.target.style.transform = 'translateY(0)';
                }
            });
        }, { threshold: 0.1, rootMargin: '0px 0px -50px 0px' });

        animatedElements.forEach(el => {
            el.style.opacity = '0';
            el.style.transform = 'translateY(30px)';
            el.style.transition = 'opacity 0.6s ease, transform 0.6s ease';
            observer.observe(el);
        });
    }

    // Home button hover effect
    const homeButton = document.querySelector('.home-button');
    if (homeButton) {
        homeButton.addEventListener('mouseenter', function () {
            this.style.transform = 'translateY(-2px)';
            this.style.boxShadow = '0px 8px 25px rgba(0, 0, 0, 0.3)';
        });
        homeButton.addEventListener('mouseleave', function () {
            this.style.transform = 'translateY(0)';
            this.style.boxShadow = '0px 0px 10px rgba(0, 0, 0, 0.25)';
        });
    }

    // Parallax effect for backdrop
    const backdrop = document.querySelector('.backdrop');
    if (backdrop) {
        let ticking = false;
        function updateParallax() {
            const scrolled = window.pageYOffset;
            const rate = scrolled * -0.2;
            backdrop.style.transform = `translateY(${rate}px)`;
            ticking = false;
        }
        function requestTick() {
            if (!ticking) {
                requestAnimationFrame(updateParallax);
                ticking = true;
            }
        }
        window.addEventListener('scroll', requestTick);
    }

    // Scroll-to-top button
    if (!document.querySelector('.scroll-to-top')) {
        let scrollToTopBtn = document.createElement('button');
        scrollToTopBtn.innerHTML = '↑';
        scrollToTopBtn.className = 'scroll-to-top';
        scrollToTopBtn.style.cssText = `
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: #b45252;
            color: white;
            border: none;
            border-radius: 50%;
            width: 50px;
            height: 50px;
            font-size: 20px;
            cursor: pointer;
            opacity: 0;
            transition: all 0.3s ease;
            z-index: 1000;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.2);
        `;
        document.body.appendChild(scrollToTopBtn);

        window.addEventListener('scroll', function () {
            if (window.pageYOffset > 300) {
                scrollToTopBtn.style.opacity = '1';
                scrollToTopBtn.style.pointerEvents = 'auto';
            } else {
                scrollToTopBtn.style.opacity = '0';
                scrollToTopBtn.style.pointerEvents = 'none';
            }
        });
        scrollToTopBtn.addEventListener('click', function () {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });
        scrollToTopBtn.addEventListener('mouseenter', function () {
            this.style.background = '#9d2828';
            this.style.transform = 'scale(1.1)';
        });
        scrollToTopBtn.addEventListener('mouseleave', function () {
            this.style.background = '#b45252';
            this.style.transform = 'scale(1)';
        });
    }
});

// --- Results Page Script ---
document.addEventListener('DOMContentLoaded', function () {
    // Table filter
    const filterInput = document.getElementById('tableSearch');
    if (filterInput) {
        filterInput.addEventListener('input', function () {
            const filterValue = this.value.toLowerCase();
            const rows = document.querySelectorAll('.table-row');
            let visibleCount = 0;
            rows.forEach(row => {
                const cells = row.querySelectorAll('.table-cell');
                let rowVisible = false;
                cells.forEach(cell => {
                    const cellText = cell.textContent || cell.innerText;
                    if (cellText.toLowerCase().includes(filterValue)) {
                        rowVisible = true;
                    }
                });
                if (rowVisible) {
                    row.style.display = '';
                    visibleCount++;
                    row.style.animation = 'none';
                    row.offsetHeight;
                    row.style.animation = 'slideInLeft 0.3s ease-out';
                } else {
                    row.style.display = 'none';
                }
            });
            updateResultCount(visibleCount);
        });
    }

    function updateResultCount(count) {
        const countBadge = document.querySelector('.count-badge');
        if (countBadge) {
            const totalResults = document.querySelectorAll('.table-row').length;
            countBadge.textContent = count === totalResults
                ? `${totalResults} publications found`
                : `${count} of ${totalResults} publications shown`;
        }
    }

    // Expand/collapse long text in table
    window.toggleText = function (button) {
        const textContent = button.parentElement;
        const cell = textContent.parentElement;
        const fullText = cell.getAttribute('data-fulltext');
        const textPreview = textContent.querySelector('.text-preview');
        const expandIcon = button.querySelector('.expand-icon');
        if (cell.getAttribute('data-expanded') === 'true') {
            textPreview.textContent = fullText.substring(0, 100) + '...';
            cell.setAttribute('data-expanded', 'false');
            expandIcon.style.transform = 'rotate(0deg)';
            button.title = 'Show full text';
        } else {
            textPreview.textContent = fullText;
            cell.setAttribute('data-expanded', 'true');
            expandIcon.style.transform = 'rotate(180deg)';
            button.title = 'Show less';
        }
    };

    // Table row hover effect
    const tableRows = document.querySelectorAll('.table-row');
    tableRows.forEach(row => {
        row.addEventListener('mouseenter', function () {
            this.style.background = 'rgba(211, 174, 170, 0.15)';
            this.style.boxShadow = '0 4px 20px rgba(180, 82, 82, 0.1)';
        });
        row.addEventListener('mouseleave', function () {
            this.style.background = '';
            this.style.boxShadow = '';
        });
    });

    // Scroll-to-top button for results page (if not already present)
    if (!document.querySelector('.scroll-to-top')) {
        let scrollToTopBtn = document.createElement('button');
        scrollToTopBtn.innerHTML = '↑';
        scrollToTopBtn.className = 'scroll-to-top';
        scrollToTopBtn.style.cssText = `
            position: fixed;
            bottom: 30px;
            right: 30px;
            background: #b45252;
            color: white;
            border: none;
            border-radius: 50%;
            width: 50px;
            height: 50px;
            font-size: 20px;
            cursor: pointer;
            opacity: 0;
            transition: all 0.3s ease;
            z-index: 1000;
            box-shadow: 0 4px 15px rgba(180, 82, 82, 0.3);
        `;
        document.body.appendChild(scrollToTopBtn);

        window.addEventListener('scroll', function () {
            if (window.pageYOffset > 300) {
                scrollToTopBtn.style.opacity = '1';
                scrollToTopBtn.style.pointerEvents = 'auto';
            } else {
                scrollToTopBtn.style.opacity = '0';
                scrollToTopBtn.style.pointerEvents = 'none';
            }
        });
        scrollToTopBtn.addEventListener('click', function () {
            window.scrollTo({ top: 0, behavior: 'smooth' });
        });
        scrollToTopBtn.addEventListener('mouseenter', function () {
            this.style.background = '#9d2828';
            this.style.transform = 'scale(1.1)';
        });
        scrollToTopBtn.addEventListener('mouseleave', function () {
            this.style.background = '#b45252';
            this.style.transform = 'scale(1)';
        });
    }

    // Download button loading state
// — fixed download with spinner + explicit submit —
const downloadBtn = document.querySelector('.download-btn');
if (downloadBtn) {
  downloadBtn.addEventListener('click', function (e) {
    e.preventDefault();                        // stop any default
    const form = this.closest('form');         // find the download <form>

    const originalHTML = this.innerHTML;
    // show spinner
    this.innerHTML = `
      <svg class="download-icon animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24" width="20" height="20">
        <path stroke-linecap="round" stroke-linejoin="round" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
      </svg>
      Downloading...
    `;
    this.disabled = true;

    form.submit();                              // now manually submit

    // (optional) if you ever navigate back to this page and want to re-enable:
    // setTimeout(() => {
    //   this.innerHTML = originalHTML;
    //   this.disabled = false;
    // }, 5000);
  });
}
    // Responsive table scroll indicator
    function handleTableResponsive() {
        const table = document.querySelector('.results-table');
        const wrapper = document.querySelector('.table-wrapper');
        if (table && wrapper) {
            if (window.innerWidth < 768) {
                if (!document.querySelector('.scroll-indicator')) {
                    const scrollIndicator = document.createElement('div');
                    scrollIndicator.className = 'scroll-indicator';
                    scrollIndicator.innerHTML = '← Scroll horizontally to view all columns →';
                    scrollIndicator.style.cssText = `
                        text-align: center;
                        padding: 10px;
                        background: #fff3cd;
                        color: #856404;
                        font-size: 12px;
                        border-top: 1px solid #ffeaa7;
                    `;
                    wrapper.parentNode.insertBefore(scrollIndicator, wrapper.nextSibling);
                }
            } else {
                const indicator = document.querySelector('.scroll-indicator');
                if (indicator) indicator.remove();
            }
        }
    }
    handleTableResponsive();
    window.addEventListener('resize', handleTableResponsive);

    // Lazy load row animations
    const rowObserver = new IntersectionObserver(function (entries) {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.style.opacity = '1';
                entry.target.style.transform = 'translateX(0)';
            }
        });
    }, { threshold: 0.1, rootMargin: '50px 0px' });

    const rows = document.querySelectorAll('.table-row');
    rows.forEach((row, index) => {
        if (index > 10) {
            row.style.opacity = '0';
            row.style.transform = 'translateX(-20px)';
            row.style.transition = 'opacity 0.4s ease, transform 0.4s ease';
            rowObserver.observe(row);
        }
    });
});

// --- Pagination Function (Global Scope) ---
window.changePage = function (page) {
    const form = document.getElementById('searchForm');
    if (!form) return;
    let pageInput = form.querySelector('input[name="page"]');
    if (!pageInput) {
        pageInput = document.createElement('input');
        pageInput.type = 'hidden';
        pageInput.name = 'page';
        form.appendChild(pageInput);
    }
    pageInput.value = page;
    form.submit();
};
