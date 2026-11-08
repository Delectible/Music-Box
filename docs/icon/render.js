const {chromium}=require('playwright');(async()=>{const b=await chromium.launch();const p=await b.newPage();
const base='file://'+process.argv[2];const out=process.argv[3];
const jobs=JSON.parse(process.argv[4]);
for(const j of jobs){await p.setViewportSize({width:j.px,height:j.px});await p.goto(`${base}?layer=${j.layer}&px=${j.px}&legacy=${j.legacy||''}`);await p.waitForTimeout(50);
await p.locator('svg').screenshot({path:`${out}/${j.name}.png`,omitBackground:true});}
await b.close();})();
