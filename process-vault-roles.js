const fs = require('fs');
const path = require('path');

const roleBlocks = {
    'db': `        [[ if var \"vault_db_role\" . ]]\n        role = \"[[ var \"vault_db_role\" . ]]\"
        [[ else if var \"vault_default_role\" . ]]\n        role = \"[[ var \"vault_default_role\" . ]]\"
        [[ end ]]`,
    'redis': `        [[ if var \"vault_redis_role\" . ]]\n        role = \"[[ var \"vault_redis_role\" . ]]\"
        [[ else if var \"vault_default_role\" . ]]\n        role = \"[[ var \"vault_default_role\" . ]]\"
        [[ end ]]`,
    'rserve': `        [[ if var \"vault_rserve_role\" . ]]\n        role = \"[[ var \"vault_rserve_role\" . ]]\"
        [[ else if var \"vault_default_role\" . ]]\n        role = \"[[ var \"vault_default_role\" . ]]\"
        [[ end ]]`,
    'web': `        [[ if var \"vault_default_role\" . ]]\n        role = \"[[ var \"vault_default_role\" . ]]\"
        [[ end ]]`,
    'worker': `        [[ if var \"vault_default_role\" . ]]\n        role = \"[[ var \"vault_default_role\" . ]]\"
        [[ end ]]`,
};

const templates = [
    'templates/db.nomad.tpl',
    'templates/redis.nomad.tpl',
    'templates/rserve.nomad.tpl',
    'templates/web.nomad.tpl',
    'templates/worker.nomad.tpl'
];

async function processTemplate(file) {
    const content = await fs.promises.readFile(file, 'utf8');
    const lines = content.split('\n');
    let output = [];
    let inVaultBlock = false;
    
    for (const line of lines) {
        output.push(line);
        
        if (line.includes('vault {')) {
            inVaultBlock = true;
            // Insert role block after 'vault {'
            output.push(roleBlocks[file.match(/db.*?tp\.tpl$/)?['db'] :
                                 file.match(/redis.*?tp\.tpl$/)?['redis'] :
                                 file.match(/rserve.*?tp\.tpl$/)?['rserve'] :
                                 file.match(/web.*?tp\.tpl$/)?['web'] :
                                 file.match(/worker.*?tp\.tpl$/)?['worker']]));
        }
        
        if (line.includes('}')) {
            inVaultBlock = false;
        }
    }

    await fs.promises.writeFile(file, output.join('\n'));
}

(async () => {
    for (const file of templates) {
        try {
            await processTemplate(file);
            console.log(`✅ Processed ${file}`);
        } catch (error) {
            console.error(`❌ Failed to process ${file}:`, error.message);
        }
    }
})();
